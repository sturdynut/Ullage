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
    /// Token savers: the section's data, and the switches and installs the
    /// page can ask for. Nil serves the page without the section.
    private let savers: SaverControl?

    public init(
        store: Store,
        push: PushService? = nil,
        savers: SaverControl? = nil,
        sessionLimit: Int = 20,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.push = push
        self.savers = savers
        self.sessionLimit = sessionLimit
        self.now = now
    }

    public func respond(to request: HTTPServer.Request) -> HTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(WebPage.page)

        case ("GET", "/state.json"):
            // A read that throws is a database problem, not a reason to drop
            // the connection: the page shows "not reachable" either way, and a
            // 500 with the message in it is what makes it debuggable.
            do {
                return .json(try ServeSnapshot.build(store: store, sessionId: request.query["session"], savers: savers,
                                                     sessionLimit: sessionLimit, now: now()).json())
            } catch {
                return .text(500, "state unavailable: \(error)")
            }

        case ("GET", "/dashboard.json"):
            do {
                let dashboard = try store.usageDashboard(ServeDashboard.options(from: request.query), now: now())
                return .json(try ServeDashboard(dashboard).json())
            } catch {
                return .text(500, "dashboard unavailable: \(error)")
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

        #if canImport(CryptoKit)
        case ("GET", "/push-key.json"):
            guard let push else { return .text(501, "alerts are not enabled in this process") }
            do {
                let key = try push.applicationKey(now: now())
                return .json(Data(#"{"publicKey":"\#(key.publicKey)"}"#.utf8))
            } catch {
                return .text(500, "no application key: \(error)")
            }

        case ("POST", "/subscribe"):
            guard push != nil else { return .text(501, "alerts are not enabled in this process") }
            do {
                let incoming = try JSONDecoder().decode(IncomingSubscription.self, from: request.body)
                // Every alert becomes a signed POST to this URL, so it has to
                // be a push service and not whatever a request said it was.
                guard ServeRouter.isPushEndpoint(incoming.endpoint) else {
                    return .text(400, "endpoint must be an https URL")
                }
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
        #else
        case ("GET", "/push-key.json"), ("POST", "/subscribe"):
            return .text(501, "this build cannot send push notifications")
        #endif

        case ("GET", "/healthz"):
            return .text(200, "ok")

        case ("GET", "/savers/plan"):
            // Read-only: the exact commands, so the page can show them before
            // asking. Nothing runs here.
            guard let savers else { return .text(501, "token savers are not served by this process") }
            guard let saver = request.query["saver"].flatMap(TokenSaver.init(rawValue:)),
                  let action = request.query["action"].flatMap(SaverAction.init(rawValue:)) else {
                return .text(400, "saver and action (install|uninstall) required")
            }
            let plan = savers.plan(saver, action)
            return .json(PlanJSON(plan).data)

        case ("POST", "/savers"):
            // The one request that changes the Mac. A loopback server can be
            // POSTed to by any page the Mac's browser has open, and the host
            // check alone does not stop that, so the request must also come
            // from this page: its own Origin, and a header a cross-site form
            // cannot send without a CORS preflight this server never answers.
            guard let savers else { return .text(501, "token savers are not served by this process") }
            guard ServeRouter.isSameOrigin(request) else {
                return .text(403, "only this page can change token savers")
            }
            guard let body = try? JSONDecoder().decode(SaverRequest.self, from: request.body),
                  let saver = TokenSaver(rawValue: body.saver) else {
                return .text(400, "expected {\"saver\": …, \"action\": on|off|undo|install|uninstall}")
            }
            do {
                switch body.action {
                case "on": try savers.set(saver, on: true, now: now())
                case "off": try savers.set(saver, on: false, now: now())
                case "undo": try savers.undo(saver, now: now())
                case "install": try savers.run(saver, .install, now: now())
                case "uninstall": try savers.run(saver, .uninstall, now: now())
                default: return .text(400, "unknown action \(body.action)")
                }
                return .text(200, "ok")
            } catch {
                return .text(409, "\(error)")
            }

        default:
            return .text(404, "no such path")
        }
    }

    /// The request names this page as its origin and carries the page's own
    /// header. `Origin`'s host must equal `Host`: a page elsewhere sends its
    /// own origin, and cannot add `X-Ullage` without a preflight.
    static func isSameOrigin(_ request: HTTPServer.Request) -> Bool {
        guard request.headers["x-ullage"] == "1",
              let origin = request.headers["origin"], let host = request.host,
              let url = URL(string: origin), let originHost = url.host else { return false }
        let originAuthority = originHost + (url.port.map { ":\($0)" } ?? "")
        return originAuthority.lowercased() == host.lowercased()
            || originHost.lowercased() == host.lowercased()
    }

    struct SaverRequest: Decodable {
        let saver: String
        let action: String
    }

    /// What the page shows before it asks.
    struct PlanJSON: Encodable {
        struct Step: Encodable { let command: String; let purpose: String; let interactive: Bool }
        let saver: String
        let action: String
        let steps: [Step]
        let missing: [String]
        let notes: [String]
        let runnable: Bool
        let needsPerson: Bool

        init(_ plan: InstallPlan) {
            saver = plan.saver.displayName
            action = plan.action.rawValue
            steps = plan.steps.map { Step(command: $0.command, purpose: $0.purpose, interactive: $0.interactive) }
            missing = plan.missing
            notes = plan.notes
            runnable = plan.isRunnable
            needsPerson = plan.needsPerson
        }

        var data: Data { (try? JSONEncoder().encode(self)) ?? Data("{}".utf8) }
    }

    /// A browser only ever hands out `https://` endpoints, and a push service
    /// is never on loopback or a bare IP. Anything else is not a subscription.
    static func isPushEndpoint(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint), url.scheme == "https", let host = url.host?.lowercased() else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".local") { return false }
        // Dotted quads and bracketed v6 literals are not push services.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.contains(":") { return false }
        return host.contains(".")
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
