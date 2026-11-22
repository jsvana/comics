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
                    .border(Color.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RootView(environment: environment)
            }
        }
    }
}

/// Reads the window size it is given and derives the layout form from it. Shows the reader when
/// a comic is open (`-openComic <id>` opens one at launch).
struct RootView: View {
    let environment: AppEnvironment
    @State private var reader: ReaderModel?
    @State private var openError: String?

    var body: some View {
        GeometryReader { proxy in
            let form = WindowForm(size: proxy.size)
            if let reader {
                ReaderView(model: reader) { self.reader = nil }
            } else {
                VStack(spacing: 12) {
                    Text("Comics")
                        .font(.largeTitle)
                    if let openError {
                        Text(openError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("open-error")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("windowForm-\(form == .wide ? "wide" : "narrow")")
            }
        }
        .task { await openFromLaunchArgs() }
    }

    /// `-openComic <id>`: adds the comic (from its first strip) if it is not in the library, applies
    /// `-goto <n>` only when it was just added, then opens the reader.
    private func openFromLaunchArgs() async {
        guard reader == nil, let id = environment.launchArgs.openComic else { return }
        let library = environment.library
        let places = environment.places
        do {
            let catalog = try await environment.loadCatalog()
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
            reader = ReaderModel(def: def, library: library, places: places, loader: environment.loader)
        } catch {
            openError = "Couldn't open \(id): \(error.localizedDescription)"
        }
    }
}
