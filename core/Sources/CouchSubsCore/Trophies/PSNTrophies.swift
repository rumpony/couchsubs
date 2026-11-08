// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Reads the signed-in player's recent trophies from PlayStation Network.
///
/// Uses the `npsso` cookie of the player's own account (read-only trophy access, separate from the
/// Remote Play account). The cookie is exchanged for an access token with the PlayStation App's public
/// OAuth client, the same flow open-source PSN libraries use. Tokens stay in memory.
public actor PSNTrophies {
    public enum TrophyError: Error, Equatable {
        /// The npsso cookie is missing, wrong or expired; the player has to paste a new one.
        case signInExpired
        case http(Int)
        case badResponse
    }

    static let clientId = "09515159-7237-4370-9b40-3806e67c0891"
    static let basicAuth = "Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A="
    static let redirect = "com.scee.psxandroid.scecompcall://redirect"
    static let scope = "psn:mobile.v2.core psn:clientapp"
    static let authBase = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth")!
    static let apiBase = URL(string: "https://m.np.playstation.com/api/trophy/v1")!

    private let npsso: String
    private let session: URLSession
    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt = Date.distantPast
    private var tracker = TrophyTracker()

    public init(npsso: String, session: URLSession = .shared) {
        self.npsso = npsso.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    /// Trophies earned since the previous call. The first call returns nothing and sets the baseline.
    public func poll() async throws -> [EarnedTrophy] {
        let titles = try await recentTitles()
        var earned: [EarnedTrophy] = []
        for title in titles where tracker.needsFetch(lastUpdated: title.lastUpdated) {
            earned += try await earnedTrophies(of: title)
        }
        return tracker.newTrophies(in: earned)
    }

    /// Checks that the cookie works.
    public func verify() async throws {
        _ = try await token()
    }

    // MARK: - Trophies

    struct Title {
        let id: String
        let service: String
        let name: String
        let lastUpdated: Date
    }

    private func recentTitles() async throws -> [Title] {
        let json = try await get("users/me/trophyTitles", query: ["limit": "5"])
        guard let list = json["trophyTitles"] as? [[String: Any]] else { throw TrophyError.badResponse }
        return list.compactMap { item in
            guard let id = item["npCommunicationId"] as? String,
                  let service = item["npServiceName"] as? String,
                  let date = (item["lastUpdatedDateTime"] as? String).flatMap(Self.date) else { return nil }
            return Title(id: id, service: service, name: item["trophyTitleName"] as? String ?? "", lastUpdated: date)
        }
    }

    private func earnedTrophies(of title: Title) async throws -> [EarnedTrophy] {
        let query = ["npServiceName": title.service]
        async let progress = get("users/me/npCommunicationIds/\(title.id)/trophyGroups/all/trophies", query: query)
        async let details = get("npCommunicationIds/\(title.id)/trophyGroups/all/trophies", query: query)
        return Self.merge(progress: try await progress, details: try await details, game: title.name)
    }

    /// Joins the player's progress (earned, date) with the trophy details (name, icon) by trophy id.
    static func merge(progress: [String: Any], details: [String: Any], game: String) -> [EarnedTrophy] {
        let info = (details["trophies"] as? [[String: Any]] ?? []).reduce(into: [Int: [String: Any]]()) { map, item in
            if let id = item["trophyId"] as? Int { map[id] = item }
        }
        return (progress["trophies"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["earned"] as? Bool == true,
                  let id = item["trophyId"] as? Int,
                  let date = (item["earnedDateTime"] as? String).flatMap(date),
                  let detail = info[id],
                  let name = detail["trophyName"] as? String else { return nil }
            let grade = EarnedTrophy.Grade(rawValue: item["trophyType"] as? String ?? detail["trophyType"] as? String ?? "") ?? .bronze
            let icon = (detail["trophyIconUrl"] as? String).flatMap(URL.init(string:))
            return EarnedTrophy(name: name, grade: grade, game: game, iconURL: icon, earnedAt: date)
        }
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: - Requests

    private func get(_ path: String, query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { accessToken = nil }
        guard (200..<300).contains(status) else { throw TrophyError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TrophyError.badResponse }
        return json
    }

    private func token() async throws -> String {
        if let accessToken, Date() < expiresAt { return accessToken }
        if let refreshToken, let fresh = try? await requestToken(["grant_type": "refresh_token", "refresh_token": refreshToken,
                                                                     "scope": Self.scope, "token_format": "jwt"]) {
            return fresh
        }
        return try await requestToken(["grant_type": "authorization_code", "code": try await authorizationCode(),
                                       "redirect_uri": Self.redirect, "token_format": "jwt"])
    }

    /// Sony answers with a redirect that carries the code; it is read from the Location header without following it.
    private func authorizationCode() async throws -> String {
        guard !npsso.isEmpty else { throw TrophyError.signInExpired }
        var components = URLComponents(url: Self.authBase.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("npsso=\(npsso)", forHTTPHeaderField: "Cookie")
        let (_, response) = try await session.data(for: request, delegate: NoRedirect())
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let code = URLComponents(string: location)?.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw TrophyError.signInExpired }
        return code
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
        // 4xx means the grant was rejected; anything else is a temporary failure.
        if (400..<500).contains(status) { refreshToken = nil; throw TrophyError.signInExpired }
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { throw TrophyError.http(status) }
        accessToken = access
        refreshToken = json["refresh_token"] as? String ?? refreshToken
        expiresAt = Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600) - 60)
        return access
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
