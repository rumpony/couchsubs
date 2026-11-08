// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation
import Observation

/// State of the Trophies tab. Signs in with the player's own PSN account (not the Remote Play account)
/// and keeps only the refresh token, in the Keychain.
@MainActor @Observable
final class TrophyModel {
    enum Phase: Equatable { case signedOut, loading, ready, failed(String) }

    var phase: Phase
    var summary: TrophySummary?
    var titles: [TrophyTitle] = []
    var recent: [TrophyItem] = []
    /// Trophy lists already loaded, by game.
    var lists: [String: [TrophyItem]] = [:]

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let client: PSNTrophies

    init(store: AppStore) {
        self.store = store
        let saved = store.load(String.self, for: StoreKey.trophyLogin)
        client = PSNTrophies(refreshToken: saved) { token in
            Task { @MainActor in
                if let token { store.save(token, for: StoreKey.trophyLogin) } else { store.remove(StoreKey.trophyLogin) }
            }
        }
        phase = saved == nil ? .signedOut : .loading
    }

    func signIn(redirect url: URL) async {
        guard let code = PSNTrophies.code(fromRedirect: url) else { return }
        phase = .loading
        do {
            try await client.signIn(code: code)
            await refresh()
        } catch {
            phase = .failed(String(localized: "Sign-in failed. Try again."))
        }
    }

    func signOut() {
        Task { await client.signOut() }
        summary = nil
        titles = []
        recent = []
        lists = [:]
        phase = .signedOut
    }

    /// Loads the level, the game list and the latest trophies from the three most recently played games.
    func refresh() async {
        guard await client.isSignedIn else { phase = .signedOut; return }
        if titles.isEmpty { phase = .loading }
        do {
            async let summary = client.summary()
            async let titles = client.titles()
            self.summary = try await summary
            self.titles = try await titles
            var latest: [TrophyItem] = []
            for title in self.titles.prefix(3) { latest += try await list(for: title) }
            recent = TrophyLists.recent(latest, limit: 10)
            phase = .ready
        } catch PSNTrophies.TrophyError.signedOut {
            signOut()
        } catch {
            phase = titles.isEmpty ? .failed(String(localized: "Could not reach PlayStation Network.")) : .ready
        }
    }

    func list(for title: TrophyTitle) async throws -> [TrophyItem] {
        if let cached = lists[title.id] { return cached }
        let items = try await client.trophies(of: title)
        lists[title.id] = items
        return items
    }
}
