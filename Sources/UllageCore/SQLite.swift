import Foundation
import CSQLite

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    public var description: String {
        switch self {
        case .open(let message): return "sqlite open failed: \(message)"
        case .prepare(let message, let sql): return "sqlite prepare failed: \(message) — \(sql)"
        case .step(let message, let sql): return "sqlite step failed: \(message) — \(sql)"
        }
    }
}

// SQLITE_TRANSIENT tells SQLite to copy bound bytes; the Swift string is gone
// by the time the statement runs otherwise.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite binding. Not thread-safe by design: one connection per
/// owner, single writer.
public final class SQLiteDatabase {
    let handle: OpaquePointer

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError.open(message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(error)
            throw SQLiteError.step(message, sql: sql)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteError.prepare(lastErrorMessage, sql: sql)
        }
        return SQLiteStatement(handle: statement, sql: sql, database: self)
    }

    @discardableResult
    public func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bind(bindings)
        try statement.stepDone()
        return Int(sqlite3_changes(handle))
    }

    public func query<T>(
        _ sql: String,
        _ bindings: [SQLiteValue] = [],
        row: (SQLiteStatement) -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bind(bindings)
        var results: [T] = []
        while try statement.step() { results.append(row(statement)) }
        return results
    }

    /// All-or-nothing. Rows and the file cursor that describes them must land
    /// together or a crash mid-batch re-reads the same lines.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

public enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public static func int(_ value: Int?) -> SQLiteValue {
        value.map { .integer(Int64($0)) } ?? .null
    }

    public static func uint(_ value: UInt64) -> SQLiteValue { .integer(Int64(bitPattern: value)) }

    public static func string(_ value: String?) -> SQLiteValue {
        value.map { .text($0) } ?? .null
    }

    public static func bool(_ value: Bool?) -> SQLiteValue {
        value.map { .integer($0 ? 1 : 0) } ?? .null
    }

    public static func double(_ value: Double?) -> SQLiteValue {
        value.map { .real($0) } ?? .null
    }
}

public final class SQLiteStatement {
    let handle: OpaquePointer
    let sql: String
    private unowned let database: SQLiteDatabase

    init(handle: OpaquePointer, sql: String, database: SQLiteDatabase) {
        self.handle = handle
        self.sql = sql
        self.database = database
    }

    public func finalize() { sqlite3_finalize(handle) }

    public func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(handle, position)
            case .integer(let v): sqlite3_bind_int64(handle, position, v)
            case .real(let v): sqlite3_bind_double(handle, position, v)
            case .text(let v): sqlite3_bind_text(handle, position, v, -1, sqliteTransient)
            }
        }
    }

    @discardableResult
    public func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(database.lastErrorMessage, sql: sql)
        }
    }

    public func stepDone() throws {
        while try step() {}
    }

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    public func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(handle, index)) }

    public func optionalInt(_ index: Int32) -> Int? { isNull(index) ? nil : int(index) }

    public func double(_ index: Int32) -> Double { sqlite3_column_double(handle, index) }

    public func text(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, index) else { return "" }
        return String(cString: pointer)
    }

    public func optionalText(_ index: Int32) -> String? { isNull(index) ? nil : text(index) }

    public func optionalBool(_ index: Int32) -> Bool? { optionalInt(index).map { $0 != 0 } }
}
