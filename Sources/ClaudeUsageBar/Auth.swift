import Foundation

/// Claude Code OAuth credentials, mirrored from the keychain JSON:
/// { "claudeAiOauth": { accessToken, refreshToken, expiresAt, scopes, subscriptionType, rateLimitTier } }
struct Credentials: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double            // epoch milliseconds
    var scopes: [String]?
    var subscriptionType: String?
    var rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt, scopes, subscriptionType, rateLimitTier
    }

    var isExpired: Bool {
        // Treat as expired a minute early to avoid races on a request in flight.
        Date().timeIntervalSince1970 * 1000 >= (expiresAt - 60_000)
    }
}

private struct Wrapper: Codable { var claudeAiOauth: Credentials }

enum AuthError: Error { case noCredentials, staleToken }

/// Passive reader of the Claude Code OAuth credentials in the keychain.
///
/// ClaudeUsageBar never refreshes or writes the shared `Claude Code-credentials`
/// item — Claude Code is the sole owner and refresher. We only ever read it and
/// adopt whatever valid token is already there. Keeping a single writer means the
/// keychain item's access-control list is never reset out from under either app,
/// which is what caused the repeated "security wants to access" prompts.
final class Auth {
    /// In-memory cache so the per-minute polling does NOT hit the keychain
    /// every time (which would trigger a keychain prompt on every poll).
    /// The keychain is read only when this cache is empty or expired.
    private var cached: Credentials?

    /// Health of the shared keychain item, for the `--doctor` report and the
    /// menu. Deliberately returns no token material.
    enum Status {
        case ok(expiresAt: Date, subscription: String?)
        case expired(since: Date, subscription: String?)
        case missing
    }

    func status() -> Status {
        guard let creds = try? currentCredentials() else { return .missing }
        let expiry = Date(timeIntervalSince1970: creds.expiresAt / 1000)
        return creds.isExpired
            ? .expired(since: expiry, subscription: creds.subscriptionType)
            : .ok(expiresAt: expiry, subscription: creds.subscriptionType)
    }

    func currentCredentials() throws -> Credentials {
        guard let raw = Keychain.readRaw(),
              let data = raw.data(using: .utf8),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data)
        else { throw AuthError.noCredentials }
        return wrapper.claudeAiOauth
    }

    /// Returns a valid access token. Touches the keychain only when the cached
    /// token is missing or expired — roughly once every several hours, not every poll.
    /// If the stored token is expired we surface `.staleToken` rather than refreshing;
    /// Claude Code will rotate it on its next use and we'll pick the new one up.
    func validAccessToken() throws -> String {
        if let c = cached, !c.isExpired { return c.accessToken }

        // Cache cold/expired: re-read the keychain and adopt Claude Code's token.
        let creds = try currentCredentials()
        guard !creds.isExpired else { throw AuthError.staleToken }
        cached = creds
        return creds.accessToken
    }
}
