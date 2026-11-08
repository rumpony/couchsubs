// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import SwiftUI
import WebKit

/// Trophies tab: level, latest trophies and every game with its trophy list.
struct TrophiesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn = false

    private var trophies: TrophyModel { model.trophies }

    var body: some View {
        NavigationStack {
            Group {
                switch trophies.phase {
                case .signedOut: signIn
                case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message): failure(message)
                case .ready: content
                }
            }
            .navigationTitle(Text("Trophies"))
            .navigationDestination(for: TrophyTitle.self) { GameTrophiesView(title: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if trophies.phase == .ready {
                    ToolbarItem { Button("Sign out") { trophies.signOut() } }
                }
            }
        }
        .frame(width: 560, height: 680)
        .task { if trophies.phase == .loading { await trophies.refresh() } }
        .sheet(isPresented: $signingIn) {
            VStack(spacing: 0) {
                HStack {
                    Text("Sign in with your own PSN account").font(.csHeadline)
                    Spacer()
                    Button("Cancel") { signingIn = false }
                }
                .padding(Theme.space("l"))
                TrophySignInWebView { url in
                    signingIn = false
                    Task { await trophies.signIn(redirect: url) }
                }
            }
            .frame(width: 520, height: 680)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: Theme.space("l")) {
            Card(title: "Your trophies") {
                HintText(text: "Sign in with your own PlayStation account to see your level, your games and every trophy, with how rare each one is. This is separate from the Remote Play account; only your trophies are read.")
                Button("Sign in to PlayStation Network") { signingIn = true }
                    .buttonStyle(CSButtonStyle(kind: .primary, fullWidth: true))
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.space("xxl"))
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: Theme.space("l")) {
            Text(verbatim: message).font(.csBody).foregroundStyle(Color.csWarning)
            Button("Try again") { Task { await trophies.refresh() } }.buttonStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.space("xl")) {
                if let summary = trophies.summary {
                    Card {
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(format: String(localized: "Level %d"), summary.level)).font(.csTitle)
                            Spacer()
                            Text(verbatim: "\(summary.progress)%").font(.csCallout).foregroundStyle(Color.csSecondary)
                        }
                        ProgressView(value: Double(summary.progress), total: 100).tint(Color.csAccent)
                        GradeCounts(counts: summary.earned)
                    }
                }
                if !trophies.recent.isEmpty {
                    Card(title: "Latest trophies") {
                        ForEach(trophies.recent.prefix(5)) { item in
                            TrophyRow(item: item, showGame: true)
                        }
                    }
                }
                Card(title: "Games") {
                    ForEach(trophies.titles) { title in
                        NavigationLink(value: title) { GameRow(title: title) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.space("xxl"))
        }
        .refreshable { await trophies.refresh() }
    }
}

/// One game's trophies: progress, the easiest ones still missing, then the full list.
struct GameTrophiesView: View {
    @Environment(AppModel.self) private var model
    let title: TrophyTitle
    @State private var items: [TrophyItem]?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.space("xl")) {
                Card {
                    GameRow(title: title)
                    GradeCounts(counts: title.earned, total: title.defined)
                }
                if let items {
                    let easiest = TrophyLists.easiest(items)
                    if !easiest.isEmpty {
                        Card(title: "Easiest next") {
                            HintText(text: "Missing trophies that most players have.")
                            ForEach(easiest) { TrophyRow(item: $0) }
                        }
                    }
                    Card(title: "All trophies") {
                        ForEach(items) { TrophyRow(item: $0) }
                    }
                } else if failed {
                    Text("Could not reach PlayStation Network.").font(.csBody).foregroundStyle(Color.csWarning)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.space("xxl"))
        }
        .navigationTitle(Text(verbatim: title.name))
        .task {
            do { items = try await model.trophies.list(for: title) } catch { failed = true }
        }
    }
}

struct GameRow: View {
    let title: TrophyTitle

    var body: some View {
        HStack(spacing: Theme.space("m")) {
            TrophyIcon(url: title.iconURL, size: 48)
            VStack(alignment: .leading, spacing: Theme.space("xs")) {
                Text(verbatim: title.name).font(.csBody.weight(.semibold)).lineLimit(1)
                HStack(spacing: Theme.space("s")) {
                    ProgressView(value: Double(title.progress), total: 100).tint(Color.csAccent)
                    Text(verbatim: "\(title.progress)%").font(.csCaption.monospacedDigit()).foregroundStyle(Color.csSecondary)
                }
            }
            if title.earned.platinum > 0 { GradeDot(grade: .platinum) }
        }
        .contentShape(Rectangle())
    }
}

struct TrophyRow: View {
    let item: TrophyItem
    var showGame = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space("m")) {
            TrophyIcon(url: item.iconURL, size: 40).opacity(item.earned ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.space("s")) {
                    GradeDot(grade: item.grade)
                    Text(verbatim: item.hidden && !item.earned ? String(localized: "Hidden trophy") : item.name)
                        .font(.csBody.weight(.semibold))
                }
                Text(verbatim: showGame ? item.game : (item.hidden && !item.earned ? "" : item.detail))
                    .font(.csCallout).foregroundStyle(Color.csSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if let rate = item.earnedRate {
                    Text(verbatim: String(format: "%.1f%%", rate)).font(.csCaption.monospacedDigit()).foregroundStyle(Color.csSecondary)
                }
                if let date = item.earnedAt {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                        .font(.csCaption).foregroundStyle(Color.csSuccess)
                }
            }
        }
    }
}

struct GradeCounts: View {
    let counts: TrophyCounts
    var total: TrophyCounts?

    var body: some View {
        HStack(spacing: Theme.space("l")) {
            ForEach(TrophyGrade.allCases, id: \.self) { grade in
                HStack(spacing: Theme.space("xs")) {
                    GradeDot(grade: grade)
                    Text(verbatim: total.map { "\(counts[grade])/\($0[grade])" } ?? "\(counts[grade])")
                        .font(.csCallout.monospacedDigit())
                }
            }
        }
    }
}

struct GradeDot: View {
    let grade: TrophyGrade

    var body: some View {
        Image(systemName: "trophy.fill")
            .font(.system(size: 12))
            .foregroundStyle(color)
            .accessibilityLabel(Text(verbatim: grade.rawValue))
    }

    private var color: Color {
        switch grade {
        case .platinum: Color(red: 0.72, green: 0.83, blue: 0.98)
        case .gold: Color(red: 0.95, green: 0.78, blue: 0.30)
        case .silver: Color(red: 0.80, green: 0.82, blue: 0.85)
        case .bronze: Color(red: 0.80, green: 0.55, blue: 0.36)
        }
    }
}

struct TrophyIcon: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.csSurface
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Sony sign-in for the player's own account; returns the redirect carrying the one-time code.
struct TrophySignInWebView: NSViewRepresentable {
    let onRedirect: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRedirect: onRedirect) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: PSNTrophies.signInURL))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onRedirect: (URL) -> Void
        init(onRedirect: @escaping (URL) -> Void) { self.onRedirect = onRedirect }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = action.request.url, PSNTrophies.code(fromRedirect: url) != nil {
                onRedirect(url)
                return .cancel
            }
            return .allow
        }
    }
}
