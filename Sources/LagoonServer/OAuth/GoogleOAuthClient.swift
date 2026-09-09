import Foundation

public struct GoogleTokenResult: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int
    public let scope: String
    public let tokenType: String
    public let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
        case idToken = "id_token"
    }
}

public struct GoogleUserInfo: Codable, Sendable {
    // Google's OIDC /userinfo endpoint returns the unique subject as `sub`,
    // not `id` (the legacy `id` field only existed on the retired v1 endpoint).
    public let sub: String
    public let email: String
}

public final class GoogleOAuthClient: Sendable {
    public let clientID: String
    public let clientSecret: String
    public let redirectURI: String
    public let scopes: [String]
    private let session: URLSession

    public init(
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        scopes: [String] = [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/userinfo.email",
            "openid"
        ],
        session: URLSession = .outbound
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.session = session
    }

    public func authorizeURL(state: String, codeChallenge: String) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]
        return c.url!
    }

    public func exchange(
        code: String,
        codeVerifier: String
    ) async throws -> GoogleTokenResult {
        let body = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        try OutboundGuard.validate(req.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
            .map { "\($0.key)=\(Self.percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthClientError.http(
                (resp as? HTTPURLResponse)?.statusCode ?? 0,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try JSONDecoder().decode(GoogleTokenResult.self, from: data)
    }

    public func fetchUserInfo(accessToken: String) async throws -> GoogleUserInfo {
        var req = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        try OutboundGuard.validate(req.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthClientError.http(
                (resp as? HTTPURLResponse)?.statusCode ?? 0,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try JSONDecoder().decode(GoogleUserInfo.self, from: data)
    }

    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+=&")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

public enum OAuthClientError: Error {
    case http(Int, String)
}