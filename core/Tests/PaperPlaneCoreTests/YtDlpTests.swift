import Foundation
import Testing
@testable import PaperPlaneCore

/// A shell script stands in for yt-dlp (decision 1). It records its arguments and standard input,
/// then does what the test says.
struct FakeYtDlp {
    let folder: URL
    let executable: URL

    /// `body` runs after the recording; `$DIR` is the folder.
    init(_ body: String) throws {
        folder = try TestSupport.makeTemporaryDirectory()
        executable = folder.appendingPathComponent("yt-dlp")
        let script = """
        #!/bin/sh
        DIR='\(folder.path)'
        printf '%s\\n' "$@" > "$DIR/arguments"
        cat > "$DIR/stdin"
        printf '%s' "$PATH" > "$DIR/path"
        echo $$ > "$DIR/pid"
        \(body)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    /// Prints `json` as yt-dlp's answer.
    static func answering(_ json: String) throws -> FakeYtDlp {
        let fake = try FakeYtDlp(#"cat "$DIR/answer.json""#)
        try json.write(to: fake.folder.appendingPathComponent("answer.json"), atomically: true, encoding: .utf8)
        return fake
    }

    func recorded(_ name: String) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    var pid: pid_t? {
        recorded("pid").flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

struct YtDlpTests {
    let page = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!

    func resolve(with fake: FakeYtDlp, cookie: String? = "SID=abc; HSID=def",
                 timeLimit: Duration = .seconds(60)) async throws -> ResolvedPage {
        try await YtDlp.resolve(page: page, cookie: cookie, executable: fake.executable,
                                cacheFolder: fake.folder.appendingPathComponent("cache"), fallbackTitle: "Tab",
                                timeLimit: timeLimit, environment: ["PATH": "/usr/bin:/bin"])
    }

    @Test(.timeLimit(.minutes(1))) func resolvesThroughTheExecutable() async throws {
        let fake = try FakeYtDlp.answering(YtDlpFixtures.youtube)
        let resolved = try await resolve(with: fake)
        #expect(resolved.input.inputs.count == 2)
        #expect(resolved.input.page == page)
        #expect(fake.recorded("arguments") == YtDlpCommand.arguments(page: page, cacheFolder: fake.folder.appendingPathComponent("cache"))
            .joined(separator: "\n") + "\n")
        #expect(fake.recorded("stdin") == "--add-headers 'Cookie:SID=abc; HSID=def'\n")
        #expect(fake.recorded("path") == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    /// The browser's cookie reaches www.youtube.com's requests whatever YouTube host the tab was on.
    @Test func aYouTubePageReachesYtDlpAsWwwYouTube() async throws {
        let fake = try FakeYtDlp.answering(YtDlpFixtures.youtube)
        _ = try await YtDlp.resolve(page: URL(string: "https://m.youtube.com/watch?v=aqz-KE-bpKQ")!, cookie: "SID=1",
                                    executable: fake.executable, cacheFolder: fake.folder, fallbackTitle: "Tab")
        #expect(fake.recorded("arguments")?.hasSuffix("--\nhttps://www.youtube.com/watch?v=aqz-KE-bpKQ\n") == true)
    }

    /// yt-dlp, and whatever stands in its place, gets none of Paper Plane's privacy permissions:
    /// a disclaimed child's responsible process is itself (security review, Plan 5).
    @Test(.timeLimit(.minutes(1))) func ytDlpIsItsOwnResponsibleProcess() async throws {
        let fake = try FakeYtDlp("sleep 1; cat \"$DIR/answer.json\"")
        try YtDlpFixtures.single.write(to: fake.folder.appendingPathComponent("answer.json"), atomically: true, encoding: .utf8)
        let resolving = Task { try await resolve(with: fake) }
        for _ in 0..<100 where fake.pid == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(fake.pid)
        let responsible = try #require(Self.responsiblePID(for: pid), "no responsibility SPI on this macOS")
        #expect(responsible == pid, "yt-dlp's responsible process is \(responsible), not itself")
        _ = try await resolving.value
    }

    /// The process macOS holds responsible for `pid`'s privacy permissions (a private call, as
    /// browsers use for their helpers).
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Responsible.self)(pid)
    }

    /// Spec §5.4: on standard input, never on the command line, where any process can read it.
    @Test func theCookieIsNeverOnTheCommandLine() async throws {
        let fake = try FakeYtDlp.answering(YtDlpFixtures.single)
        _ = try await resolve(with: fake, cookie: "SECRET=hush")
        #expect(fake.recorded("arguments")?.contains("hush") == false)
        #expect(fake.recorded("stdin")?.contains("SECRET=hush") == true)
    }

    @Test func aFailureCarriesYtDlpsReason() async throws {
        let fake = try FakeYtDlp("""
        echo "ERROR: [youtube] aqz-KE-bpKQ: Private video. Sign in if you've been granted access to this video" >&2
        exit 1
        """)
        await #expect(throws: YtDlpFailure.failed(reason: "Private video.")) { try await resolve(with: fake) }
    }

    /// A site that never answers isn't waited for for ever (decision 8), and yt-dlp doesn't linger.
    @Test func aSilentYtDlpIsStoppedAtTheTimeLimit() async throws {
        let fake = try FakeYtDlp("exec sleep 30")
        let started = ContinuousClock.now
        await #expect(throws: YtDlpFailure.timedOut) { try await resolve(with: fake, timeLimit: .milliseconds(500)) }
        #expect(ContinuousClock.now - started < .seconds(5))
        if let pid = fake.pid {
            #expect(await Self.ends(pid), "yt-dlp is still running")
        }
    }

    /// Stopping the playback, or another video, stops yt-dlp (Review Focus 2).
    @Test func stoppingWhileResolvingStopsYtDlp() async throws {
        let fake = try FakeYtDlp("exec sleep 30")
        let resolving = Task { try await resolve(with: fake) }
        for _ in 0..<100 where fake.pid == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(fake.pid)
        resolving.cancel()
        await #expect(throws: CancellationError.self) { try await resolving.value }
        #expect(await Self.ends(pid), "yt-dlp is still running")
    }

    /// Whether `pid` is gone within a second (an exited process can take a moment to be reaped).
    static func ends(_ pid: pid_t) async -> Bool {
        for _ in 0..<50 {
            if kill(pid, 0) != 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func aMissingExecutableIsSaidSo() async throws {
        await #expect(throws: YtDlpFailure.missing) {
            try await YtDlp.resolve(page: page, cookie: nil, executable: URL(fileURLWithPath: "/nonexistent/yt-dlp"),
                                    cacheFolder: URL(fileURLWithPath: "/tmp"), fallbackTitle: "Tab")
        }
    }

    /// yt-dlp exits 0 but prints something that isn't its answer: no video, not a crash.
    @Test func aGarbledAnswerIsUnsupported() async throws {
        let fake = try FakeYtDlp("echo 'not json'")
        await #expect(throws: YtDlpFailure.unsupported) { try await resolve(with: fake) }
    }
}
