// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class SubtitleHistoryTests: XCTestCase {
    func testNewestComesFirst() {
        var history = SubtitleHistory()
        history.add(source: "Stay close, boy.", translation: "Yakın dur, evlat.")
        history.add(source: "The gate will not hold.", translation: "Kapı dayanmayacak.")
        XCTAssertEqual(history.entries.map(\.translation), ["Kapı dayanmayacak.", "Yakın dur, evlat."])
    }

    func testRereadOfSameLineUpdatesInsteadOfAdding() {
        var history = SubtitleHistory()
        history.add(source: "The gate will not hold.", translation: "Kapı dayanmayacak.")
        history.add(source: "The gale will not hold.", translation: "Kapı tutmayacak.")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].translation, "Kapı tutmayacak.")
    }

    func testEmptyTranslationIsIgnored() {
        var history = SubtitleHistory()
        history.add(source: "...", translation: "  ")
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testOldestDropsPastLimit() {
        var history = SubtitleHistory(limit: 2)
        history.add(source: "One line here", translation: "Bir")
        history.add(source: "Second different sentence", translation: "İki")
        history.add(source: "Third unrelated words", translation: "Üç")
        XCTAssertEqual(history.entries.map(\.translation), ["Üç", "İki"])
        XCTAssertEqual(Set(history.entries.map(\.id)).count, 2)
    }
}
