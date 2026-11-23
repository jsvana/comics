import SwiftUI

@main
struct ComicsApp: App {
    private let environment = AppEnvironment.current

    var body: some Scene {
        WindowGroup {
            if let canvas = environment.launchArgs.canvas {
                // Simulator testing: `-canvas 951x669` renders at the open
                // Duo's inner-screen size (no Duo simulator runtime exists).
                RootView(environment: environment)
                    .frame(width: canvas.width, height: canvas.height)
                    .debugCanvasBorder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RootView(environment: environment)
            }
        }
    }
}

private extension View {
    /// Outlines the `-canvas` frame in debug builds only.
    @ViewBuilder
    func debugCanvasBorder() -> some View {
        #if DEBUG
        border(Color.red)
        #else
        self
        #endif
    }
}

/// Reads the window size it is given and derives the layout form from it. Shows the library, or
/// the reader when a comic is open (`-openComic <id>` opens one at launch). Each time the app
/// becomes active it runs the launch upkeep (`AppEnvironment.becameActive`); while it exists it
/// restores comics that an iCloud change reveals (`AppEnvironment.followCloudChanges`).
struct RootView: View {
    let environment: AppEnvironment
    @State private var library: LibraryModel
    @State private var reader: ReaderModel?
    @State private var openError: String?
    @State private var offline = false
    @State private var upkeepRunning = false
    @Environment(\.scenePhase) private var scenePhase

    init(environment: AppEnvironment) {
        self.environment = environment
        _library = State(initialValue: LibraryModel(env: environment))
    }

    var body: some View {
        GeometryReader { proxy in
            let form = WindowForm(size: proxy.size)
            Group {
                if let reader {
                    ReaderView(model: reader, offline: offline) { self.reader = nil }
                } else {
                    LibraryView(model: library, form: form, offline: offline, onOpen: open)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("windowForm-\(form == .wide ? "wide" : "narrow")")
        }
        .alert("Couldn't open the comic", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
        .task { await openFromLaunchArgs() }
        .task { await environment.followCloudChanges { await library.reload() } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await upkeep()
        }
        .task(id: scenePhase) { await watchConnection() }
    }

    private func open(_ card: ComicSummary) {
        guard let def = card.def else { return }
        let places = environment.places
        do {
            reader = try ReaderModel(def: def, library: environment.library, places: places, loader: environment.loader)
        } catch {
            openError = Self.unreadablePlace(def.title)
            return
        }
        Task.detached { places.markRead(def.id) }
    }

    /// Shown instead of opening the reader at strip 1 when the saved place cannot be read.
    private static func unreadablePlace(_ title: String) -> String {
        "Couldn't read your place in \(title), so the comic was not opened (opening it at the start could overwrite your place). Try again in a moment."
    }

    private func upkeep() async {
        guard !upkeepRunning else { return }
        upkeepRunning = true
        defer { upkeepRunning = false }
        await environment.becameActive()
        await library.reload()
        reader?.libraryChanged()  // upkeep may have appended strips to the open comic
    }

    /// Mirrors the loader's "last request failed for want of a connection" into the offline banner
    /// while the app is active.
    private func watchConnection() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            let failed = await environment.loader.lastTransportFailed
            if failed != offline { offline = failed }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// `-openComic <id>`: adds the comic (from its first strip) if it is not in the library, applies
    /// `-goto <n>` only when it was just added, then opens the reader.
    private func openFromLaunchArgs() async {
        guard reader == nil, let id = environment.launchArgs.openComic else { return }
        let library = environment.library
        let places = environment.places
        do {
            let catalog = environment.catalog.catalog
            let (stored, active) = await Task.detached { (library.definition(id), library.activeIDs().contains(id)) }.value
            guard let def = stored ?? catalog.comics.first(where: { $0.id == id }) else {
                openError = "There is no comic called “\(id)”."
                return
            }
            if !active {
                try await library.add(def, start: .first)
                if let goto = environment.launchArgs.goto {
                    await Task.detached { places.step(id, to: goto) }.value
                }
            }
            guard let model = try? ReaderModel(def: def, library: library, places: places, loader: environment.loader) else {
                openError = Self.unreadablePlace(def.title)
                return
            }
            await Task.detached { places.markRead(id) }.value
            reader = model
        } catch {
            openError = "Couldn't open \(id): \(error.localizedDescription)"
        }
    }
}
