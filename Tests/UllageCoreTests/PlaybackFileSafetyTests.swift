import Foundation
import XCTest

@testable import UllageCore

final class PlaybackFileSafetyTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testRepeatedTranscriptPathDoesNotDuplicateEventsAcrossSourceAgents() throws {
    let url = directory.appendingPathComponent("session.jsonl")
    try Data("{\"type\":\"user\",\"sessionId\":\"s1\",\"message\":{\"content\":\"Hello\"}}\n".utf8)
      .write(to: url)
    let reader = SessionPlaybackReader()
    let source = PlaybackSource(path: url.path, vendor: Vendor.claudeCode)
    let expected = reader.read(sessionId: "s1", sources: [source])
    XCTAssertEqual(expected.events.count, 1)
    let result = reader.read(sessionId: "s1", sources: [
      source, PlaybackSource(path: url.path, vendor: Vendor.claudeCode, agentId: "child")
    ])
    XCTAssertEqual(result.events, expected.events)
  }

  func testMetadataStaysWithOpenedFileAfterPathIsReplaced() throws {
    let url = directory.appendingPathComponent("request.json")
    let original = Data("original".utf8)
    try original.write(to: url)
    let reader = SessionPlaybackReader()
    let handle = try reader.regularHandle(url)
    defer { try? handle.close() }
    let before = try reader.confinedInfo(handle, directoryPath: directory.path)
    try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("old.json"))
    try Data("different replacement".utf8).write(to: url)
    let after = try reader.confinedInfo(handle, directoryPath: directory.path)
    XCTAssertEqual(after.st_ino, before.st_ino)
    XCTAssertEqual(Int(after.st_size), original.count)
    XCTAssertEqual(try handle.readToEnd(), original)
  }

  func testOpenedFileRejectsParentDirectorySymlinkSwap() throws {
    let recordings = directory.appendingPathComponent("recordings")
    let nested = recordings.appendingPathComponent("nested")
    let outside = directory.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let checkedURL = nested.appendingPathComponent("request.json").resolvingSymlinksInPath()
    try Data("outside contents".utf8).write(to: outside.appendingPathComponent("request.json"))
    try FileManager.default.removeItem(at: nested)
    try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
    let reader = SessionPlaybackReader()
    let handle = try reader.regularHandle(checkedURL)
    defer { try? handle.close() }
    XCTAssertThrowsError(try reader.confinedInfo(handle, directoryPath: recordings.path))
  }

  func testOpenedFileRejectsSelectedDirectorySymlinkSwap() throws {
    let recordings = directory.appendingPathComponent("recordings")
    let outside = directory.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let checkedRoot = recordings.resolvingSymlinksInPath()
    let checkedURL = checkedRoot.appendingPathComponent("request.json")
    try Data("outside contents".utf8).write(to: outside.appendingPathComponent("request.json"))
    try FileManager.default.removeItem(at: recordings)
    try FileManager.default.createSymbolicLink(at: recordings, withDestinationURL: outside)
    let reader = SessionPlaybackReader()
    let handle = try reader.regularHandle(checkedURL)
    defer { try? handle.close() }
    XCTAssertThrowsError(try reader.confinedInfo(handle, directoryPath: checkedRoot.path))
  }
}
