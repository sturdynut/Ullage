import Foundation

/// Maps a request to a response. Separated from the socket so the routing is
/// testable without binding a port, and so the app can serve the same things
/// the CLI does without either of them owning the rules.
public struct ServeRouter {
    private let store: Store
    private let sessionLimit: Int
    private let now: () -> Date
    /// Absent on a build that cannot push (no CryptoKit) or when alerts are
    /// switched off; the page copes, and says why.
    private let push: PushService?

    public init(
        store: Store,
        push: PushService? = nil,
        sessionLimit: Int = 20,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.push = push
        self.sessionLimit = sessionLimit
        self.now = now
    }

    public func respond(to request: HTTPServer.Request) -> HTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(WebPage.html)

        case ("GET", "/state.json"):
            // A read that throws is a database problem, not a reason to drop
            // the connection: the page shows "not reachable" either way, and a
            // 500 with the message in it is what makes it debuggable.
            do {
                return .json(try ServeSnapshot.build(store: store, sessionLimit: sessionLimit, now: now()).json())
            } catch {
                return .text(500, "state unavailable: \(error)")
            }

        case ("GET", "/manifest.webmanifest"):
            return HTTPServer.Response(
                contentType: "application/manifest+json; charset=utf-8",
                body: Data(WebPage.manifest.utf8)
            )

        case ("GET", "/sw.js"):
            // Served from the root so its scope is the whole origin; a worker
            // registered from a subdirectory could not control the page.
            return HTTPServer.Response(
                contentType: "text/javascript; charset=utf-8",
                body: Data(WebPage.serviceWorker.utf8)
            )

        case ("GET", "/icon.png"):
            return HTTPServer.Response(contentType: "image/png", body: WebIcon.png)

        case ("GET", "/push-key.json"):
            guard let push else { return .text(501, "this build cannot send push notifications") }
            do {
                let key = try push.applicationKey(now: now())
                return .json(Data(#"{"publicKey":"\#(key.publicKey)"}"#.utf8))
            } catch {
                return .text(500, "no application key: \(error)")
            }

        case ("POST", "/subscribe"):
            guard push != nil else { return .text(501, "this build cannot send push notifications") }
            do {
                let incoming = try JSONDecoder().decode(IncomingSubscription.self, from: request.body)
                try store.upsert(subscription: PushSubscription(
                    endpoint: incoming.endpoint,
                    p256dh: incoming.keys.p256dh,
                    auth: incoming.keys.auth,
                    createdAt: Timestamps.string(from: now())
                ))
                return .text(200, "subscribed")
            } catch {
                return .text(400, "not a push subscription: \(error)")
            }

        case ("GET", "/healthz"):
            return .text(200, "ok")

        default:
            return .text(404, "no such path")
        }
    }

    /// The shape `PushSubscription.toJSON()` produces in a browser.
    struct IncomingSubscription: Decodable {
        struct Keys: Decodable {
            let p256dh: String
            let auth: String
        }
        let endpoint: String
        let keys: Keys
    }
}
