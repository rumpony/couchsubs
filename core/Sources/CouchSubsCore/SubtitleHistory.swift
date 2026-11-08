// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Oturumda çevrilen altyazılar, en yenisi başta. Hızlı geçen bir satır sonradan yeniden okunabilsin diye tutulur.
public struct SubtitleHistory: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Sendable {
        public let id: Int
        public let source: String
        public let translation: String
    }

    public private(set) var entries: [Entry] = []
    public let limit: Int
    private var nextID = 0

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    /// Yeni çeviriyi başa ekler. Aynı satırın yeniden okuması (benzer kaynak metin) yeni kayıt açmaz, son kaydı günceller.
    public mutating func add(source: String, translation: String) {
        let translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else { return }
        if let last = entries.first,
           TextMatch.isSimilar(TextMatch.normalize(last.source), TextMatch.normalize(source)) {
            entries[0] = Entry(id: last.id, source: source, translation: translation)
            return
        }
        entries.insert(Entry(id: nextID, source: source, translation: translation), at: 0)
        nextID += 1
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public mutating func clear() {
        entries.removeAll()
    }
}
