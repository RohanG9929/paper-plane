import Foundation
import Testing
@testable import PaperPlaneCore

struct RedactionTests {
    @Test func removesQueryStrings() {
        let text = "https://cdn.example.com/v/seg1.ts?token=SECRET&exp=99: Server returned 403 Forbidden"
        #expect(Redaction.redactQueries(text) == "https://cdn.example.com/v/seg1.ts?… Server returned 403 Forbidden")
    }

    @Test func summaryKeepsLastTwentyLinesRedacted() {
        let text = (1...30).map { "line \($0) https://x.test/a?k=\($0)" }.joined(separator: "\n")
        let summary = Redaction.summary(of: Data(text.utf8))
        let lines = summary.split(separator: "\n")
        #expect(lines.count == 20)
        #expect(lines.first == "line 11 https://x.test/a?…")
        #expect(!summary.contains("k="))
    }
}
