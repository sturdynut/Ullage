import Foundation
import XCTest
@testable import UllageCore

enum Fixtures {
    static var directory: URL {
        // Tests/UllageCoreTests/TestSupport.swift -> Tests/Fixtures
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func lines(_ name: String) throws -> [String] {
        try String(contentsOf: url(name), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

/// A scratch directory plus an on-disk database, torn down with the test.
final class TempWorkspace {
    let root: URL
    let store: Store
    let ingestor: Ingestor

    init(environmentProvider: SessionEnvironmentProviding? = nil) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ullage-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try Store(path: root.appendingPathComponent("telemetry.db").path)
        // Tests never read the real ~/.claude unless they ask for it.
        ingestor = Ingestor(store: store, environmentProvider: environmentProvider)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ name: String, lines: [String], terminated: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name)
        var text = lines.joined(separator: "\n")
        if terminated, !text.isEmpty { text += "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func append(_ name: String, text: String) throws {
        let url = root.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func copyFixture(_ name: String) throws -> URL {
        let destination = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: Fixtures.url(name), to: destination)
        return destination
    }
}
