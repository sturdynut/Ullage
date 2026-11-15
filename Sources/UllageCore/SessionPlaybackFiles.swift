import Foundation

extension SessionPlaybackReader {
  func load(
    path: String, source: PlaybackSource?, sessionId: String, notices: inout [String],
    recordingDirectoryPath: String? = nil
  )
    -> FileState? {
    do {
      let attrs = try FileManager.default.attributesOfItem(atPath: path)
      guard attrs[.type] as? FileAttributeType == .typeRegular else {
        notices.append(
          "Source is not a regular file: \(URL(fileURLWithPath: path).lastPathComponent).")
        files.removeValue(forKey: path)
        return nil
      }
      let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
      let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      var state = files[path] ?? FileState()
      if state.inode != inode || size < state.offset || (size == state.size && mtime != state.mtime) {
        state = FileState()
      }
      state.inode = inode
      state.mtime = mtime
      state.size = size
      if state.offset < size {
        let handle = try regularHandle(URL(fileURLWithPath: path))
        defer { try? handle.close() }
        if let recordingDirectoryPath { _ = try confinedInfo(handle, directoryPath: recordingDirectoryPath) }
        try handle.seek(toOffset: state.offset)
        try readAppend(
          handle: handle, size: size, source: source, sessionId: sessionId, state: &state)
      }
      files[path] = state
      if state.offset < size {
        notices.append("Loading more of \(URL(fileURLWithPath: path).lastPathComponent)…")
      }
      if state.malformed > 0 {
        notices.append(
          "Skipped \(state.malformed) malformed lines in \(URL(fileURLWithPath: path).lastPathComponent)."
        )
      }
      if state.oversized > 0 {
        notices.append(
          "Skipped \(state.oversized) lines exceeding 16 MiB in \(URL(fileURLWithPath: path).lastPathComponent)."
        )
      }
      return state
    } catch {
      files.removeValue(forKey: path)
      notices.append(
        "Source missing or unreadable: \(URL(fileURLWithPath: path).lastPathComponent). "
          + "Recordings remain in their original location."
      )
      return nil
    }
  }

  private func readAppend(
    handle: FileHandle, size: UInt64, source: PlaybackSource?,
    sessionId: String, state: inout FileState
  ) throws {
    while state.offset < size && remainingRefreshBytes > 0 {
      let data = try handle.read(upToCount: min(256 * 1_024, remainingRefreshBytes)) ?? Data()
      if data.isEmpty { break }
      remainingRefreshBytes -= data.count
      for byte in data {
        state.offset += 1
        if byte == 10 {
          acceptLine(source: source, sessionId: sessionId, state: &state)
          state.pending.removeAll(keepingCapacity: true)
          state.droppingLine = false
          state.lineOffset = state.offset
        } else if !state.droppingLine {
          state.pending.append(byte)
          if state.pending.count > maxContentBytes {
            state.pending.removeAll(keepingCapacity: false)
            state.droppingLine = true
            state.oversized += 1
          }
        }
      }
      trimState(&state)
    }
  }

  private func trimState(_ state: inout FileState) {
    var bytes = 0
    var count = 0
    for event in state.events.reversed() {
      let size = event.text.utf8.count
      if count == 10_000 || bytes + size > maxRefreshBytes { break }
      bytes += size
      count += 1
    }
    if count < state.events.count {
      state.events = Array(state.events.suffix(count))
      state.eventIDs = Set(state.events.map(\.id))
      state.omitted = true
    }
  }

  private func acceptLine(source: PlaybackSource?, sessionId: String, state: inout FileState) {
    guard !state.droppingLine, !state.pending.isEmpty else { return }
    guard let root = (try? JSONSerialization.jsonObject(with: state.pending)) as? [String: Any]
    else {
      state.malformed += 1
      return
    }
    guard let source else {
      acceptIndex(root, sessionId: sessionId, state: &state)
      return
    }
    let parsed = parse(
      root, source: source, sessionId: sessionId, offset: state.lineOffset, state: &state)
    let updated = Set(parsed.map(\.id))
    if !state.eventIDs.isDisjoint(with: updated) {
      state.events.removeAll { updated.contains($0.id) }
    }
    state.eventIDs.formUnion(updated)
    state.events += parsed
  }

  private func acceptIndex(_ root: [String: Any], sessionId: String, state: inout FileState) {
    guard root["session_id"] as? String == sessionId else { return }
    let record = root.filter { ["session_id", "message_id", "request_file"].contains($0.key) }
    guard record.count == 3,
      record.values.allSatisfy({ (($0 as? String)?.utf8.count ?? Int.max) <= 4_096 })
    else {
      state.malformed += 1
      return
    }
    state.records.append(record)
    if state.records.count > 10_000 {
      state.records.removeFirst(state.records.count - 10_000)
      state.omitted = true
    }
  }

}
