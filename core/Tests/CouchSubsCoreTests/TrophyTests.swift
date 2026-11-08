// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class TrophyTests: XCTestCase {
    private func trophy(_ name: String, at seconds: TimeInterval) -> EarnedTrophy {
        EarnedTrophy(name: name, grade: .bronze, game: "Game", iconURL: nil, earnedAt: Date(timeIntervalSince1970: seconds))
    }

    func testFirstCheckOnlySetsBaseline() {
        var tracker = TrophyTracker()
        XCTAssertEqual(tracker.newTrophies(in: [trophy("Old", at: 100)], now: Date(timeIntervalSince1970: 200)), [])
    }

    func testLaterTrophiesAreReturnedOnceOldestFirst() {
        var tracker = TrophyTracker()
        _ = tracker.newTrophies(in: [trophy("Old", at: 100)], now: Date(timeIntervalSince1970: 200))
        let all = [trophy("Old", at: 100), trophy("B", at: 320), trophy("A", at: 310)]
        XCTAssertEqual(tracker.newTrophies(in: all).map(\.name), ["A", "B"])
        XCTAssertEqual(tracker.newTrophies(in: all), [])
    }

    func testOnlyTitlesPlayedSinceBaselineAreFetched() {
        var tracker = TrophyTracker()
        XCTAssertTrue(tracker.needsFetch(lastUpdated: Date(timeIntervalSince1970: 0)))
        _ = tracker.newTrophies(in: [], now: Date(timeIntervalSince1970: 200))
        XCTAssertFalse(tracker.needsFetch(lastUpdated: Date(timeIntervalSince1970: 150)))
        XCTAssertTrue(tracker.needsFetch(lastUpdated: Date(timeIntervalSince1970: 250)))
    }

    func testMergeJoinsProgressWithDetails() {
        let progress: [String: Any] = ["trophies": [
            ["trophyId": 1, "earned": true, "earnedDateTime": "2026-11-08T12:00:00Z", "trophyType": "gold"],
            ["trophyId": 2, "earned": false],
        ]]
        let details: [String: Any] = ["trophies": [
            ["trophyId": 1, "trophyName": "Night Owl", "trophyIconUrl": "https://example.com/1.png"],
            ["trophyId": 2, "trophyName": "Locked"],
        ]]
        let merged = PSNTrophies.merge(progress: progress, details: details, game: "Some Game")
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "Night Owl")
        XCTAssertEqual(merged[0].grade, .gold)
        XCTAssertEqual(merged[0].game, "Some Game")
        XCTAssertEqual(merged[0].iconURL, URL(string: "https://example.com/1.png"))
    }

    func testDateParsesWithAndWithoutFraction() {
        XCTAssertNotNil(PSNTrophies.date("2026-11-08T12:00:00Z"))
        XCTAssertNotNil(PSNTrophies.date("2026-11-08T12:00:00.123Z"))
    }
}
