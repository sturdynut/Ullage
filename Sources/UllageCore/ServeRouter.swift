import Foundation

/// Maps a request to a response. Separated from the socket so the routing is
/// testable without binding a port, and so the app can serve the same three
/// things the CLI does without either of them owning the rules.
public struct ServeRouter {
    private let store: Store
    private let sessionLimit: Int
    private let now: () -> Date

    public init(store: Store, sessionLimit: Int = 20, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.sessionLimit = sessionLimit
        self.now = now
    }

    public func respond(to request: HTTPServer.Request) -> HTTPServer.Response {
        switch request.path {
        case "/", "/index.html":
            return .html(WebPage.html)
        case "/state.json":
            // A read that throws is a database problem, not a reason to drop
            // the connection: the page shows "not reachable" either way, and a
            // 500 with the message in it is what makes it debuggable.
            do {
                return .json(try ServeSnapshot.build(store: store, sessionLimit: sessionLimit, now: now()).json())
            } catch {
                return .text(500, "state unavailable: \(error)")
            }
        case "/healthz":
            return .text(200, "ok")
        default:
            return .text(404, "no such path")
        }
    }
}
