// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Trophy earned since the previous check, ready to show on the TV.
public struct EarnedTrophy: Equatable, Sendable {
    public enum Grade: String, Sendable { case bronze, silver, gold, platinum }

    public let name: String
    public let grade: Grade
    public let game: String
    public let iconURL: URL?
    public let earnedAt: Date

    public init(name: String, grade: Grade, game: String, iconURL: URL?, earnedAt: Date) {
        self.name = name
        self.grade = grade
        self.game = game
        self.iconURL = iconURL
        self.earnedAt = earnedAt
    }
}

/// Decides which trophies are new. The first check only records a baseline, so trophies earned before
/// the session started are never announced.
public struct TrophyTracker: Sendable {
    private var since: Date?

    public init() {}

    /// Returns the trophies earned after the baseline, oldest first, and moves the baseline forward.
    public mutating func newTrophies(in earned: [EarnedTrophy], now: Date = Date()) -> [EarnedTrophy] {
        guard let since else {
            self.since = max(now, earned.map(\.earnedAt).max() ?? now)
            return []
        }
        let fresh = earned.filter { $0.earnedAt > since }.sorted { $0.earnedAt < $1.earnedAt }
        if let latest = fresh.last?.earnedAt { self.since = latest }
        return fresh
    }

    /// Only titles played after the baseline need their trophy lists fetched.
    public func needsFetch(lastUpdated: Date) -> Bool {
        guard let since else { return true }
        return lastUpdated > since
    }

    public mutating func reset() {
        since = nil
    }
}
