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
    /// Modification date of the keychain item at the moment we last read its
    /// secret. Used to skip re-reads when nothing has been rotated.
    private var cachedItemDate: Date?

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

        // The token we hold is missing or expired. Before reading the secret
        // again — the one operation that can raise a keychain prompt — check the
        // item's modification date, which costs nothing and never prompts. If it
        // has not changed since our last read, the same expired token is still
        // in there and re-reading it would prompt for nothing.
        //
        // This mattered: with an expired token, `cached` was never populated, so
        // every 5-minute poll performed a fresh secret read. Whenever the ACL was
        // invalidated (any rebuild changes the code identity), that became a
        // password prompt every five minutes.
        let itemDate = Keychain.modificationDate()
        if cached != nil, let itemDate, let cachedItemDate, itemDate == cachedItemDate {
            throw AuthError.staleToken
        }

        let creds = try currentCredentials()
        cachedItemDate = itemDate
        // Hold on to it even when expired, so the check above has something to
        // compare against on the next poll.
        cached = creds
        guard !creds.isExpired else { throw AuthError.staleToken }
        return creds.accessToken
    }
}
