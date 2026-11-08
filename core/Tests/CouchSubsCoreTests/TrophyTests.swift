// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class TrophyTests: XCTestCase {
    private func item(_ id: Int, earned: Bool, rate: Double?, at: TimeInterval? = nil) -> TrophyItem {
        TrophyItem(id: id, name: "T\(id)", detail: "", grade: .bronze, iconURL: nil, hidden: false, earned: earned,
                   earnedAt: at.map(Date.init(timeIntervalSince1970:)), earnedRate: rate, groupId: "default")
    }

    func testEasiestSkipsEarnedAndUnknownRates() {
        let items = [item(1, earned: true, rate: 90), item(2, earned: false, rate: 40), item(3, earned: false, rate: 70),
                     item(4, earned: false, rate: nil)]
        XCTAssertEqual(TrophyLists.easiest(items).map(\.id), [3, 2])
    }

    func testRecentIsNewestFirst() {
        let items = [item(1, earned: true, rate: 1, at: 100), item(2, earned: true, rate: 1, at: 300), item(3, earned: false, rate: 1)]
        XCTAssertEqual(TrophyLists.recent(items).map(\.id), [2, 1])
    }

    func testMergeKeepsUnearnedTrophies() {
        let progress: [String: Any] = ["trophies": [
            ["trophyId": 1, "earned": true, "earnedDateTime": "2026-11-08T12:00:00Z", "trophyEarnedRate": "12.5"],
            ["trophyId": 2, "earned": false, "trophyEarnedRate": "60.1"],
        ]]
        let details: [String: Any] = ["trophies": [
            ["trophyId": 1, "trophyName": "Night Owl", "trophyType": "gold", "trophyGroupId": "default"],
            ["trophyId": 2, "trophyName": "First Steps", "trophyType": "bronze", "trophyGroupId": "001"],
        ]]
        let merged = PSNTrophies.merge(progress: progress, details: details, game: "Some Game")
        XCTAssertEqual(merged.map(\.name), ["Night Owl", "First Steps"])
        XCTAssertEqual(merged[0].grade, .gold)
        XCTAssertTrue(merged[0].earned)
        XCTAssertEqual(merged[0].earnedRate, 12.5)
        XCTAssertFalse(merged[1].earned)
        XCTAssertFalse(merged[1].isBaseGame)
        XCTAssertEqual(merged[1].game, "Some Game")
    }

    func testTitleParsing() {
        let title = PSNTrophies.title(["npCommunicationId": "NPWR1_00", "npServiceName": "trophy2", "trophyTitleName": "Game",
                                       "progress": 42, "earnedTrophies": ["gold": 2], "definedTrophies": ["gold": 5, "bronze": 10],
                                       "lastUpdatedDateTime": "2026-11-08T12:00:00.000Z"])
        XCTAssertEqual(title?.progress, 42)
        XCTAssertEqual(title?.earned.gold, 2)
        XCTAssertEqual(title?.defined.total, 15)
        XCTAssertNotNil(title?.lastUpdated)
    }

    func testSignInRedirectCode() {
        XCTAssertEqual(PSNTrophies.code(fromRedirect: URL(string: "com.scee.psxandroid.scecompcall://redirect/?code=abc")!), "abc")
        XCTAssertNil(PSNTrophies.code(fromRedirect: URL(string: "https://example.com/?code=abc")!))
    }
}
