// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Reads the player's trophies from PlayStation Network.
///
/// Signs in with the player's *own* PSN account through the PlayStation App's public OAuth client, the same
/// flow open-source PSN libraries use; this is separate from the Remote Play account. The refresh token
/// (valid for about two months) is handed to `onRefreshToken` so the app can keep it in the Keychain.
public actor PSNTrophies {
    public enum TrophyError: Error, Equatable {
        /// Not signed in, or PSN rejected the saved login; the player has to sign in again.
        case signedOut
        case http(Int)
        case badResponse
    }

    static let clientId = "09515159-7237-4370-9b40-3806e67c0891"
    static let basicAuth = "Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A="
    public static let redirect = "com.scee.psxandroid.scecompcall://redirect"
    static let scope = "psn:mobile.v2.core psn:clientapp"
    static let authBase = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth")!
    static let apiBase = URL(string: "https://m.np.playstation.com/api/trophy/v1")!

    /// Sony sign-in page for the in-app browser; it ends at `redirect` with a one-time code.
    public static let signInURL: URL = {
        var components = URLComponents(url: authBase.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
        ]
        return components.url!
    }()

    /// The one-time code in the sign-in redirect, if this is that redirect.
    public static func code(fromRedirect url: URL) -> String? {
        guard url.absoluteString.hasPrefix(redirect) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    private let session: URLSession
    private let onRefreshToken: @Sendable (String?) -> Void
    private var refreshToken: String?
    private var accessToken: String?
    private var expiresAt = Date.distantPast

    public init(refreshToken: String?, session: URLSession = .shared, onRefreshToken: @escaping @Sendable (String?) -> Void) {
        self.refreshToken = refreshToken
        self.session = session
        self.onRefreshToken = onRefreshToken
    }

    public var isSignedIn: Bool { refreshToken != nil }

    public func signIn(code: String) async throws {
        _ = try await requestToken(["grant_type": "authorization_code", "code": code,
                                    "redirect_uri": Self.redirect, "token_format": "jwt"])
    }

    public func signOut() {
        refreshToken = nil
        accessToken = nil
        onRefreshToken(nil)
    }

    // MARK: - Trophies

    public func summary() async throws -> TrophySummary {
        let json = try await get("users/me/trophySummary", query: [:])
        return TrophySummary(level: json["trophyLevel"] as? Int ?? 0, progress: json["progress"] as? Int ?? 0,
                             earned: TrophyCounts(json["earnedTrophies"]))
    }

    /// All games with trophies, most recently played first.
    public func titles() async throws -> [TrophyTitle] {
        var titles: [TrophyTitle] = []
        var offset = 0
        while true {
            let json = try await get("users/me/trophyTitles", query: ["limit": "800", "offset": "\(offset)"])
            let page = (json["trophyTitles"] as? [[String: Any]] ?? []).compactMap(Self.title)
            titles += page
            offset += page.count
            guard !page.isEmpty, offset < json["totalItemCount"] as? Int ?? 0 else { break }
        }
        return titles
    }

    /// Every trophy of `title` with the player's progress.
    public func trophies(of title: TrophyTitle) async throws -> [TrophyItem] {
        let query = ["npServiceName": title.service]
        async let progress = get("users/me/npCommunicationIds/\(title.communicationId)/trophyGroups/all/trophies", query: query)
        async let details = get("npCommunicationIds/\(title.communicationId)/trophyGroups/all/trophies", query: query)
        return Self.merge(progress: try await progress, details: try await details, game: title.name)
    }

    static func title(_ json: [String: Any]) -> TrophyTitle? {
        guard let id = json["npCommunicationId"] as? String, let service = json["npServiceName"] as? String else { return nil }
        return TrophyTitle(communicationId: id, service: service, name: json["trophyTitleName"] as? String ?? "",
                           platform: json["trophyTitlePlatform"] as? String ?? "",
                           iconURL: (json["trophyTitleIconUrl"] as? String).flatMap(URL.init(string:)),
                           progress: json["progress"] as? Int ?? 0,
                           earned: TrophyCounts(json["earnedTrophies"]), defined: TrophyCounts(json["definedTrophies"]),
                           lastUpdated: (json["lastUpdatedDateTime"] as? String).flatMap(date))
    }

    /// Joins the trophy details (name, icon) with the player's progress (earned, date, rarity) by trophy id.
    static func merge(progress: [String: Any], details: [String: Any], game: String) -> [TrophyItem] {
        let mine = (progress["trophies"] as? [[String: Any]] ?? []).reduce(into: [Int: [String: Any]]()) { map, item in
            if let id = item["trophyId"] as? Int { map[id] = item }
        }
        return (details["trophies"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["trophyId"] as? Int else { return nil }
            let own = mine[id] ?? [:]
            var trophy = TrophyItem(id: id, name: item["trophyName"] as? String ?? "", detail: item["trophyDetail"] as? String ?? "",
                                    grade: TrophyGrade(rawValue: item["trophyType"] as? String ?? "") ?? .bronze,
                                    iconURL: (item["trophyIconUrl"] as? String).flatMap(URL.init(string:)),
                                    hidden: item["trophyHidden"] as? Bool ?? false,
                                    earned: own["earned"] as? Bool ?? false,
                                    earnedAt: (own["earnedDateTime"] as? String).flatMap(date),
                                    earnedRate: (own["trophyEarnedRate"] as? String).flatMap(Double.init),
                                    groupId: item["trophyGroupId"] as? String ?? "default")
            trophy.game = game
            return trophy
        }
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: - Requests

    private func get(_ path: String, query: [String: String], retried: Bool = false) async throws -> [String: Any] {
        var components = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retried {
            // The access token may have been revoked early; refresh once and retry.
            accessToken = nil
            return try await get(path, query: query, retried: true)
        }
        guard (200..<300).contains(status) else { throw TrophyError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TrophyError.badResponse }
        return json
    }

    private func token() async throws -> String {
        if let accessToken, Date() < expiresAt { return accessToken }
        guard let refreshToken else { throw TrophyError.signedOut }
        return try await requestToken(["grant_type": "refresh_token", "refresh_token": refreshToken,
                                       "scope": Self.scope, "token_format": "jwt"])
    }

    private func requestToken(_ fields: [String: String]) async throws -> String {
        var request = URLRequest(url: Self.authBase.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue(Self.basicAuth, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Only a 4xx means the login was rejected; anything else is temporary and keeps the saved login.
        if (400..<500).contains(status) {
            signOut()
            throw TrophyError.signedOut
        }
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { throw TrophyError.http(status) }
        accessToken = access
        expiresAt = Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String, refresh != refreshToken {
            refreshToken = refresh
            onRefreshToken(refresh)
        }
        return access
    }
}
