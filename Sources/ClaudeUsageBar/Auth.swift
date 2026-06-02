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

enum AuthError: Error { case noCredentials, refreshFailed(String) }

/// Owns reading credentials from the keychain and refreshing them when expired,
/// writing the rotated tokens back so Claude Code keeps working too.
final class Auth {
    /// Public client id used by Claude Code's OAuth flow.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// In-memory cache so the per-minute polling does NOT hit the keychain
    /// every time (which would trigger a keychain prompt on every poll).
    /// The keychain is read only when this cache is empty or expired.
    private var cached: Credentials?

    func currentCredentials() throws -> Credentials {
        guard let raw = Keychain.readRaw(),
              let data = raw.data(using: .utf8),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data)
        else { throw AuthError.noCredentials }
        return wrapper.claudeAiOauth
    }

    /// Returns a valid access token. Touches the keychain only when the cached
    /// token is missing or expired — roughly once every several hours, not every poll.
    func validAccessToken() async throws -> String {
        if let c = cached, !c.isExpired { return c.accessToken }

        // Cache cold/expired: re-read the keychain. Claude Code may have already
        // refreshed the shared token, in which case we just adopt it (no refresh, no conflict).
        var creds = try currentCredentials()
        if creds.isExpired {
            creds = try await refresh(creds)
            persist(creds)
        }
        cached = creds
        return creds.accessToken
    }

    private func refresh(_ creds: Credentials) async throws -> Credentials {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": Self.clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let txt = String(data: data, encoding: .utf8) ?? "<no body>"
            throw AuthError.refreshFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(txt)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else { throw AuthError.refreshFailed("missing access_token in response") }

        var updated = creds
        updated.accessToken = access
        if let refresh = obj["refresh_token"] as? String { updated.refreshToken = refresh }
        if let expiresIn = obj["expires_in"] as? Double {
            updated.expiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        return updated
    }

    private func persist(_ creds: Credentials) {
        let wrapper = Wrapper(claudeAiOauth: creds)
        if let data = try? JSONEncoder().encode(wrapper),
           let json = String(data: data, encoding: .utf8) {
            Keychain.writeRaw(json)
        }
    }
}
