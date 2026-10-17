import Foundation

/// Addresses on the web proxy (`WebProxy`). An upstream URL keeps its path:
/// `http://127.0.0.1:<port>/<token>/<input>/<scheme>/<host[:port]>/<path>?<query>`, so the
/// relative URLs in a playlist resolve to the proxy by themselves.
struct ProxyRoute: Equatable, Sendable {
    /// `http://127.0.0.1:<port>/<token>/`
    var base: URL

    private var token: String {
        base.lastPathComponent
    }

    /// `/<token>/<input>/`, the path every proxied address starts with.
    func prefix(input: Int) -> String {
        "/\(token)/\(input)/"
    }

    func proxied(_ upstream: URL, input: Int) -> URL? {
        guard let scheme = upstream.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let components = URLComponents(url: upstream, resolvingAgainstBaseURL: true),
              let host = components.percentEncodedHost, !host.isEmpty
        else { return nil }
        let authority = components.port.map { "\(host):\($0)" } ?? host
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return URL(string: "\(base.absoluteString)\(input)/\(scheme)/\(authority)\(path)\(query)")
    }

    /// The upstream URL and input a request's target names, or nil for anything else.
    func upstream(for target: String) -> (url: URL, input: Int)? {
        let pathEnd = target.firstIndex(of: "?") ?? target.endIndex
        let parts = target[..<pathEnd].split(separator: "/", maxSplits: 4, omittingEmptySubsequences: false)
        // "", token, input, scheme, "authority/path…"
        guard parts.count == 5, parts[0].isEmpty, parts[1] == token, let input = Int(parts[2]),
              parts[3] == "http" || parts[3] == "https"
        else { return nil }
        let rest = parts[4]
        let authority = rest.prefix { $0 != "/" }
        guard !authority.isEmpty else { return nil }
        let path = rest.dropFirst(authority.count)
        guard let url = URL(string: "\(parts[3])://\(authority)\(path.isEmpty ? "/" : String(path))\(target[pathEnd...])"),
              url.host() != nil
        else { return nil }
        return (url, input)
    }
}

/// Points the addresses in HLS playlists and DASH manifests back at the proxy, so ffmpeg never
/// fetches anything from the web itself.
enum ManifestRewriter {
    enum Kind: Equatable, Sendable {
        case hls, dash
    }

    /// Whether a response is a manifest, by its type, its name or its first bytes: a playlist
    /// served under another name must not slip past the rewriting.
    static func kind(contentType: String?, url: URL, start: Data) -> Kind? {
        let type = contentType?.lowercased() ?? ""
        if type.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8" {
            return .hls
        }
        if type.contains("dash+xml") || url.pathExtension.lowercased() == "mpd" {
            return .dash
        }
        let text = String(decoding: start.prefix(2048), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"]))
        if text.hasPrefix("#EXTM3U") {
            return .hls
        }
        if text.contains("<MPD") {
            return .dash
        }
        return nil
    }

    static func rewrite(_ text: String, kind: Kind, from manifest: URL, input: Int, route: ProxyRoute) -> String {
        let scheme = manifest.scheme?.lowercased() ?? "https"
        let prefix = route.prefix(input: input)
        let authority = URLComponents(url: manifest, resolvingAgainstBaseURL: true).map { components in
            (components.percentEncodedHost ?? "") + (components.port.map { ":\($0)" } ?? "")
        } ?? ""
        // "/x" on the manifest's host, and "//host/x" on the manifest's scheme, in proxy terms.
        let localPath = { (path: Substring) -> String in
            path.hasPrefix("//") ? "\(prefix)\(scheme)/\(path.dropFirst(2))" : "\(prefix)\(scheme)/\(authority)\(path)"
        }
        // Absolute addresses, everywhere but XML namespace declarations.
        var rewritten = text.replacing(#/(xmlns(?::\w+)?=")?\b(https?)://(?=[^/\s"'<>?#])/#) { match in
            match.output.1 != nil ? String(match.output.0)
                : "\(route.base.absoluteString)\(input)/\(match.output.2.lowercased())/"
        }
        switch kind {
        case .hls:
            rewritten = rewritten.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                if !line.hasPrefix("#"), line.hasPrefix("/") {
                    return localPath(line)
                }
                return String(line).replacing(#/URI="(/[^"]*)"/#) { "URI=\"\(localPath($0.output.1))\"" }
            }.joined(separator: "\n")
        case .dash:
            rewritten = rewritten
                .replacing(#/(>\s*)(/[^<\s]*)/#) { "\($0.output.1)\(localPath($0.output.2))" }
                // After whitespace or a namespace prefix (`xlink:href`), in either quote and with or
                // without spaces around `=`. The value must start with `/`, so an absolute URL (by
                // now already the proxy's) and an `xmlns` declaration (starts with `http`) are left
                // alone; the matching closing quote is a backreference, so `'…'` closes on `'`.
                .replacing(#/((?:\s|:)(?:media|initialization|index|sourceURL|href)\s*=\s*)(?<quote>["'])(/[^"']*)\k<quote>/#) {
                    "\($0.output.1)\($0.output.quote)\(localPath($0.output.3))\($0.output.quote)"
                }
        }
        return rewritten
    }
}

/// Which hosts share a site, for cookies: the same host, or the same registrable domain (the
/// last two labels, or three under a two-part public suffix such as co.uk).
enum Site {
    private static let twoPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "ne.jp",
        "or.jp", "co.kr", "com.br", "com.cn", "com.hk", "com.tw", "co.in", "co.za", "com.mx", "com.tr", "com.sg",
    ]

    static func same(_ a: String, _ b: String) -> Bool {
        let (a, b) = (a.lowercased(), b.lowercased())
        if a == b {
            return true
        }
        if LocalAddresses.isIPAddress(a) || LocalAddresses.isIPAddress(b) {
            return false
        }
        return registrable(a) == registrable(b)
    }

    private static func registrable(_ host: String) -> String {
        let labels = host.split(separator: ".")
        let suffix = labels.suffix(2).joined(separator: ".")
        return labels.suffix(twoPartSuffixes.contains(suffix) ? 3 : 2).joined(separator: ".")
    }
}

/// This Mac and the local network: loopback, private, link-local, shared (CGNAT), multicast and
/// unspecified addresses, by literal or by what a name resolves to.
enum LocalAddresses {
    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let bare = host.trimmingCharacters(in: ["[", "]"])
        return inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
    }

    /// Resolves names (blocking): any local address makes the host local. For refusing.
    static func isLocal(_ host: String) -> Bool {
        decide(addresses(of: host), all: false)
    }

    /// Resolves names (blocking): every address must be local. For allowing local fetches, so a
    /// public name with one extra local record doesn't lift the checks.
    static func isWhollyLocal(_ host: String) -> Bool {
        decide(addresses(of: host), all: true)
    }

    /// Whether `addresses` are local: any of them, or `all`. None is never local (an unresolvable
    /// name: the fetch fails anyway). An address that isn't a literal counts as local.
    static func decide(_ addresses: [String], all: Bool) -> Bool {
        guard !addresses.isEmpty else { return false }
        let local = { (address: String) in literal(address) ?? true }
        return all ? addresses.allSatisfy(local) : addresses.contains(where: local)
    }

    /// `host` itself if it's an address, else what it resolves to.
    private static func addresses(of host: String) -> [String] {
        let bare = host.trimmingCharacters(in: ["[", "]"])
        if literal(bare) != nil {
            return [bare]
        }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(bare, nil, &hints, &results) == 0, let first = results else { return [] }
        defer { freeaddrinfo(results) }
        return sequence(first: first, next: { $0.pointee.ai_next }).map { entry in
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0,
                              NI_NUMERICHOST) == 0
            else { return "" } // not readable: counts as local
            return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// Whether an address literal is local; nil if `host` isn't one.
    private static func literal(_ host: String) -> Bool? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return isLocal(v4: UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        let address = host.split(separator: "%").first.map(String.init) ?? host // a zone (fe80::1%en0)
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { // ::ffff:a.b.c.d
            return isLocal(v4: UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15]))
        }
        let unspecifiedOrLoopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] <= 1
        return unspecifiedOrLoopback
            || bytes[0] & 0xFE == 0xFC // fc00::/7, unique local
            || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) // fe80::/10, link-local
            || bytes[0] == 0xFF // multicast
    }

    private static func isLocal(v4 address: UInt32) -> Bool {
        let ranges: [(UInt32, Int)] = [
            (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
            (0xAC10_0000, 12), (0xC0A8_0000, 16), (0xE000_0000, 4), (0xFFFF_FFFF, 32),
        ]
        return ranges.contains { network, bits in address >> (32 - bits) == network >> (32 - bits) }
    }
}
