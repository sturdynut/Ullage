import Foundation

/// One device that asked to be told when a window fills up.
///
/// `endpoint` is the push service's URL for that device and is the identity:
/// a browser hands out a new one when the old is revoked, so re-subscribing
/// after clearing site data adds a row rather than editing one.
public struct PushSubscription: Equatable {
    public var endpoint: String
    /// The device's public key, base64url, uncompressed P-256 point.
    public var p256dh: String
    /// The device's 16-byte auth secret, base64url.
    public var auth: String
    public var createdAt: String
    public var label: String?
    public var lastSentAt: String?
    /// Last HTTP status the push service returned. 201 is success; 404 and 410
    /// mean the subscription is gone and the row is deleted rather than kept.
    public var lastStatus: Int?

    public init(
        endpoint: String,
        p256dh: String,
        auth: String,
        createdAt: String,
        label: String? = nil,
        lastSentAt: String? = nil,
        lastStatus: Int? = nil
    ) {
        self.endpoint = endpoint
        self.p256dh = p256dh
        self.auth = auth
        self.createdAt = createdAt
        self.label = label
        self.lastSentAt = lastSentAt
        self.lastStatus = lastStatus
    }
}

/// The application server's identity, in the VAPID sense: one keypair per
/// database, generated on first use and never rotated on its own. Rotating it
/// invalidates every existing subscription, so it is a deliberate act.
public struct VAPIDKeyPair: Equatable {
    /// Raw P-256 private scalar, base64url.
    public var privateKey: String
    /// Uncompressed P-256 point (65 bytes, 0x04-prefixed), base64url. This is
    /// what the browser is given as `applicationServerKey`.
    public var publicKey: String
    public var createdAt: String

    public init(privateKey: String, publicKey: String, createdAt: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.createdAt = createdAt
    }
}

extension Store {

    // MARK: - Subscriptions

    public func upsert(subscription: PushSubscription) throws {
        _ = try database.run(
            """
            INSERT INTO push_subscription (endpoint, p256dh, auth, created_at, label)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(endpoint) DO UPDATE SET
              p256dh = excluded.p256dh,
              auth   = excluded.auth,
              label  = COALESCE(excluded.label, push_subscription.label);
            """,
            [
                .text(subscription.endpoint),
                .text(subscription.p256dh),
                .text(subscription.auth),
                .text(subscription.createdAt),
                subscription.label.map(SQLiteValue.text) ?? .null,
            ]
        )
    }

    public func pushSubscriptions() throws -> [PushSubscription] {
        try database.query(
            """
            SELECT endpoint, p256dh, auth, created_at, label, last_sent_at, last_status
            FROM push_subscription ORDER BY created_at;
            """
        ) { row in
            PushSubscription(
                endpoint: row.text(0),
                p256dh: row.text(1),
                auth: row.text(2),
                createdAt: row.text(3),
                label: row.optionalText(4),
                lastSentAt: row.optionalText(5),
                lastStatus: row.optionalInt(6)
            )
        }
    }

    /// A count, not a decode of every row: this runs on a timer.
    public func pushSubscriptionCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM push_subscription;") { $0.int(0) }.first ?? 0
    }

    public func deletePushSubscription(endpoint: String) throws {
        _ = try database.run("DELETE FROM push_subscription WHERE endpoint = ?1;", [.text(endpoint)])
    }

    public func recordPush(endpoint: String, status: Int, at: String) throws {
        _ = try database.run(
            "UPDATE push_subscription SET last_sent_at = ?2, last_status = ?3 WHERE endpoint = ?1;",
            [.text(endpoint), .text(at), .integer(Int64(status))]
        )
    }

    // MARK: - Application server key

    public func vapidKey() throws -> VAPIDKeyPair? {
        try database.query(
            "SELECT private_key, public_key, created_at FROM push_key WHERE id = 'vapid';"
        ) { row in
            VAPIDKeyPair(privateKey: row.text(0), publicKey: row.text(1), createdAt: row.text(2))
        }.first
    }

    public func setVAPIDKey(_ key: VAPIDKeyPair) throws {
        _ = try database.run(
            """
            INSERT INTO push_key (id, private_key, public_key, created_at)
            VALUES ('vapid', ?1, ?2, ?3)
            ON CONFLICT(id) DO UPDATE SET
              private_key = excluded.private_key,
              public_key  = excluded.public_key,
              created_at  = excluded.created_at;
            """,
            [.text(key.privateKey), .text(key.publicKey), .text(key.createdAt)]
        )
    }

    // MARK: - What has already been said

    /// The highest threshold this stream has been alerted about since it was
    /// last below all of them. Persisted rather than held in memory so that
    /// restarting `serve` does not re-announce a window it already announced.
    public func firedThreshold(streamKey: String) throws -> Double? {
        try firedAlert(streamKey: streamKey)?.threshold
    }

    /// With *when*, so a compaction recorded after it can be recognised as the
    /// thing that makes it stale — even one that was never the newest row at
    /// the moment anyone looked.
    public func firedAlert(streamKey: String) throws -> (threshold: Double, firedAt: String)? {
        try database.query(
            "SELECT threshold, fired_at FROM push_alert WHERE stream_key = ?1;",
            [.text(streamKey)]
        ) { ($0.double(0), $0.text(1)) }.first
    }

    public func setFiredThreshold(streamKey: String, threshold: Double, at: String, contextTokens: Int) throws {
        _ = try database.run(
            """
            INSERT INTO push_alert (stream_key, threshold, fired_at, context_tokens)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(stream_key) DO UPDATE SET
              threshold = excluded.threshold,
              fired_at = excluded.fired_at,
              context_tokens = excluded.context_tokens;
            """,
            [.text(streamKey), .real(threshold), .text(at), .integer(Int64(contextTokens))]
        )
    }

    /// Called when a stream drops back below every threshold — a compaction, or
    /// a new session reusing the key — so the next climb alerts again.
    public func clearFiredThreshold(streamKey: String) throws {
        _ = try database.run("DELETE FROM push_alert WHERE stream_key = ?1;", [.text(streamKey)])
    }
}
