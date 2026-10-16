import Darwin

/// The Mac's IPv4 address on the local network. The TV fetches the stream itself, so the
/// server must listen there, not on `localhost` (docs/sony-test-results.md, row 0).
public enum LANAddress {
    struct Interface: Equatable {
        var name: String
        var address: String
        var isUp: Bool
        var isLoopback: Bool
    }

    /// Wi-Fi or Ethernet, `en0` first. nil when the Mac isn't on a network.
    public static func current() -> String? {
        pick(from: interfaces())
    }

    /// Skips loopback, VPN tunnels (`utun`), bridges and self-assigned `169.254.x.x` addresses,
    /// none of which a TV on the home network can reach.
    static func pick(from interfaces: [Interface]) -> String? {
        interfaces
            .filter { $0.isUp && !$0.isLoopback && $0.name.hasPrefix("en") && !$0.address.hasPrefix("169.254.") }
            .min { (Int($0.name.dropFirst(2)) ?? .max, $0.address) < (Int($1.name.dropFirst(2)) ?? .max, $1.address) }?
            .address
    }

    static func interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }).map(\.pointee) {
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let flags = Int32(entry.ifa_flags)
            result.append(Interface(
                name: String(cString: entry.ifa_name),
                address: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                isLoopback: flags & IFF_LOOPBACK != 0))
        }
        return result
    }
}
