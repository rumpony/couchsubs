// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum TrophyGrade: String, Codable, CaseIterable, Sendable {
    case platinum, gold, silver, bronze

    /// PSN's point value for one trophy of this grade.
    public var points: Int {
        switch self {
        case .platinum: 300
        case .gold: 90
        case .silver: 30
        case .bronze: 15
        }
    }
}

public struct TrophyCounts: Equatable, Sendable {
    public var platinum = 0, gold = 0, silver = 0, bronze = 0

    public init(platinum: Int = 0, gold: Int = 0, silver: Int = 0, bronze: Int = 0) {
        self.platinum = platinum
        self.gold = gold
        self.silver = silver
        self.bronze = bronze
    }

    public var total: Int { platinum + gold + silver + bronze }

    public subscript(grade: TrophyGrade) -> Int {
        switch grade {
        case .platinum: platinum
        case .gold: gold
        case .silver: silver
        case .bronze: bronze
        }
    }

    init(_ json: Any?) {
        let json = json as? [String: Any] ?? [:]
        platinum = json["platinum"] as? Int ?? 0
        gold = json["gold"] as? Int ?? 0
        silver = json["silver"] as? Int ?? 0
        bronze = json["bronze"] as? Int ?? 0
    }
}

/// The player's trophy level and totals.
public struct TrophySummary: Equatable, Sendable {
    public let level: Int
    /// Progress to the next level, 0–100.
    public let progress: Int
    public let earned: TrophyCounts
}

/// A game in the player's trophy list.
public struct TrophyTitle: Identifiable, Hashable, Sendable {
    public var id: String { communicationId }
    public let communicationId: String
    public let service: String
    public let name: String
    public let platform: String
    public let iconURL: URL?
    /// Completion, 0–100.
    public let progress: Int
    public let earned: TrophyCounts
    public let defined: TrophyCounts
    public let lastUpdated: Date?

    public static func == (a: TrophyTitle, b: TrophyTitle) -> Bool { a.communicationId == b.communicationId }
    public func hash(into hasher: inout Hasher) { hasher.combine(communicationId) }
}

/// One trophy of a game, with the player's progress.
public struct TrophyItem: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let detail: String
    public let grade: TrophyGrade
    public let iconURL: URL?
    public let hidden: Bool
    public let earned: Bool
    public let earnedAt: Date?
    /// Share of PSN players who have it, in percent; nil when PSN does not report it.
    public let earnedRate: Double?
    public let groupId: String
    public var game = ""

    public var isBaseGame: Bool { groupId == "default" }
}

public enum TrophyLists {
    /// Unearned trophies that most players have, rarest last.
    public static func easiest(_ items: [TrophyItem], limit: Int = 5) -> [TrophyItem] {
        Array(items.filter { !$0.earned && $0.earnedRate != nil }
            .sorted { ($0.earnedRate ?? 0) > ($1.earnedRate ?? 0) }
            .prefix(limit))
    }

    /// Earned trophies, newest first.
    public static func recent(_ items: [TrophyItem], limit: Int = 20) -> [TrophyItem] {
        Array(items.filter { $0.earned && $0.earnedAt != nil }
            .sorted { $0.earnedAt! > $1.earnedAt! }
            .prefix(limit))
    }
}
