import Foundation
import XCTest
@testable import UllageCore

final class SaverAttributionTests: XCTestCase {
    func testPrefixOverlappingArgumentsKeepTheirExactRewriteOwners() {
        for (small, large, older, newer) in [
            ("foo", "foobar", "rtk ls foo", "rtk ls foobar"),
            ("foo", "foobar", "(rtk ls 'foo');", "rtk ls \"foobar\" && echo done"),
            ("foo", "\"foo'\"", "rtk ls foo", "rtk ls \"foo'\""),
            ("'foo bar'", "'foo barbaz'", "rtk ls 'foo bar'", "rtk ls 'foo barbaz'"),
            ("foo\\ bar", "foo\\ barbaz", "rtk ls foo\\ bar", "rtk ls foo\\ barbaz")
        ] {
            var entries = [small, large, small].enumerated().map { index, argument in
                LedgerEntry(saver: .rtk, ts: Date(timeIntervalSince1970: Double(index + 5)),
                            cwd: "/repo", command: "ls \(argument)", beforeTokens: 10, afterTokens: 5, savedTokens: 5)
            }
            SaverLedgers.attribute(&entries, verbs: ["ls", "ls", "ls"], to: [
                SaverLedgers.RtkDecision(timestamp: Date(timeIntervalSince1970: 1), sessionId: "small-session",
                                        toolUseId: "small-call", rewritten: older),
                SaverLedgers.RtkDecision(timestamp: Date(timeIntervalSince1970: 2), sessionId: "large-session",
                                        toolUseId: "large-call", rewritten: newer)
            ])
            XCTAssertEqual(entries.map(\.sessionId), ["small-session", "large-session", nil], older)
            XCTAssertEqual(entries.map(\.toolUseId), ["small-call", "large-call", nil], older)
        }
    }
}
