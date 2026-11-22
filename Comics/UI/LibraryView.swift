import SwiftUI

/// Home: one card per library comic (a two-column grid in the wide layout), pull to refresh,
/// long-press to remove, and the "Add comics" and settings sheets.
struct LibraryView: View {
    let model: LibraryModel
    let form: WindowForm
    let offline: Bool
    let onOpen: (ComicSummary) -> Void

    @State private var showCatalog = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            content
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("Comics")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("library-settings")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showCatalog = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add comics")
                        .accessibilityIdentifier("library-add")
                    }
                }
        }
        .sheet(isPresented: $showCatalog) { CatalogView(model: model) }
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .task { await model.reload() }
        .task(id: model.cards) { await model.loadThumbnails() }
        .onChange(of: model.env.library.revision) { _, _ in
            Task { await model.reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.loaded {
            Color.clear
        } else if model.cards.isEmpty {
            emptyState
        } else {
            ScrollView {
                if offline { OfflineRow() }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.cards, id: \.id) { card in
                        LibraryCard(card: card, thumbnail: model.thumbnails[card.id]?.image) { onOpen(card) }
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    Task { await model.remove(card.id) }
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .refreshable {
                await model.env.refreshLibrary(force: true)
                await model.reload()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library-list")
        }
    }

    private var columns: [GridItem] {
        let count = form == .wide ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if offline { OfflineRow() }
            Spacer()
            Text("No comics yet")
                .font(.title2.weight(.semibold))
            Text("Pick a comic from the catalog to start reading.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add comics") { showCatalog = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("library-empty-add")
            Spacer()
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-empty")
    }
}

/// One comic: the bookmarked strip's thumbnail, title, progress bar and status line.
private struct LibraryCard: View {
    let card: ComicSummary
    let thumbnail: CGImage?
    let onOpen: () -> Void

    private static let thumbSize: CGFloat = 72

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                thumb
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.def?.title ?? card.id)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    ProgressView(value: fraction)
                        .tint(card.status == .caughtUp ? Color.secondary : Color.accentColor)
                    Text(statusText)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if card.broken {
                        Label("This comic's recipe needs an update", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.def?.title ?? card.id)
        .accessibilityValue(card.broken ? "\(statusText). This comic's recipe needs an update" : statusText)
        .accessibilityIdentifier("card-\(card.id)")
    }

    private var thumb: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let thumbnail {
                // The top of a strip (its first panel) says more than its middle.
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.thumbSize, height: Self.thumbSize, alignment: .top)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.thumbSize, height: Self.thumbSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var fraction: Double {
        card.count > 0 ? min(Double(card.bookmark) / Double(card.count), 1) : 0
    }

    private var statusText: String {
        switch card.status {
        case .behind(let at, let of): return "\(at.formatted()) of \(of.formatted())"
        case .new(let n): return "\(n.formatted()) new"
        case .caughtUp: return "Caught up"
        }
    }
}

/// A quiet line saying strips that are not cached cannot load right now.
struct OfflineRow: View {
    var body: some View {
        Label("Offline", systemImage: "wifi.slash")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityIdentifier("offline-banner")
    }
}
