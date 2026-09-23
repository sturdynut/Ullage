import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude Code's own sign-in, read — never refreshed. Refreshing would rotate
/// the refresh token out from under Claude Code and sign it out, so an expired
/// token is reported and left for Claude Code to renew on its next request.
public struct ClaudeOAuthToken: Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?

    public func isExpired(now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// The credential blob Claude Code writes: `{"claudeAiOauth": {...}}`.
    public static func parse(_ data: Data) -> ClaudeOAuthToken? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let oauth = JSONAccess.dict(root, "claudeAiOauth")
        guard let token = JSONAccess.string(oauth, "accessToken") else { return nil }
        return ClaudeOAuthToken(
            accessToken: token,
            expiresAt: JSONAccess.double(oauth, "expiresAt").map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: JSONAccess.string(oauth, "subscriptionType")
        )
    }
}

public enum ClaudeUsageError: Error, CustomStringConvertible, Equatable {
    case notSignedIn
    case tokenExpired
    case http(Int)
    case transport(String)
    case unrecognisedResponse

    public var description: String {
        switch self {
        case .notSignedIn: return "Claude Code is not signed in with a subscription on this Mac"
        case .tokenExpired: return "Claude Code's sign-in has expired; it renews on Claude Code's next request"
        case .http(401), .http(403): return "Claude Code's sign-in was refused; run Claude Code once to renew it"
        case .http(429): return "the usage endpoint is rate-limiting; will retry later"
        case .http(let status): return "the usage endpoint answered HTTP \(status)"
        case .transport(let message): return "could not reach the usage endpoint: \(message)"
        case .unrecognisedResponse: return "the usage endpoint's answer was not in a shape Ullage knows"
        }
    }
}

/// Reads Claude plan limits from the endpoint behind Claude Code's `/usage`.
///
/// The one place Ullage makes a network request on its own. It sends Claude
/// Code's token to Anthropic — where Claude Code already sends it — and uploads
/// nothing. Off by default in the app.
public enum ClaudeUsageClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let keychainService = "Claude Code-credentials"

    /// `CLAUDE_CODE_OAUTH_TOKEN` (a `claude setup-token` token), then the macOS
    /// Keychain via `security` — already on the item's access list, because
    /// Claude Code itself uses it, so no prompt — then the credentials file
    /// Claude Code uses where there is no Keychain.
    public static func loadToken(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeOAuthToken? {
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return ClaudeOAuthToken(accessToken: token, expiresAt: nil, subscriptionType: nil)
        }
        if let data = keychainItem(), let token = ClaudeOAuthToken.parse(data) {
            return token
        }
        for directory in ClaudePaths.configDirectories(environment: environment) {
            let file = directory.appendingPathComponent(".credentials.json")
            if let data = try? Data(contentsOf: file), let token = ClaudeOAuthToken.parse(data) {
                return token
            }
        }
        return nil
    }

    static func keychainItem() -> Data? {
        let tool = URL(fileURLWithPath: "/usr/bin/security")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    /// Blocking; call it off the main thread.
    public static func fetch(
        token: ClaudeOAuthToken,
        now: Date = Date(),
        timeout: TimeInterval = 15
    ) throws -> [PlanLimitRow] {
        guard !token.isExpired(now: now) else { throw ClaudeUsageError.tokenExpired }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.setValue("Bearer " + token.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ullage", forHTTPHeaderField: "User-Agent")

        var result: Result<(Data, Int), Error> = .failure(ClaudeUsageError.transport("no response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(ClaudeUsageError.transport(error.localizedDescription))
            } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()

        let (data, status) = try result.get()
        guard status == 200 else { throw ClaudeUsageError.http(status) }
        let rows = ClaudeUsageParser.parse(data, observedAt: Timestamps.string(from: now))
        guard !rows.isEmpty else { throw ClaudeUsageError.unrecognisedResponse }
        return rows
    }

    /// Load, fetch, store. The CLI and the app share this.
    @discardableResult
    public static func refresh(into store: Store, now: Date = Date()) throws -> [PlanLimitRow] {
        guard let token = loadToken() else { throw ClaudeUsageError.notSignedIn }
        let rows = try fetch(token: token, now: now)
        try store.replacePlanLimits(vendor: Vendor.claudeCode, source: PlanLimitSource.api, with: rows)
        return rows
    }
}
