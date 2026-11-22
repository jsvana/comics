import SwiftUI

@main
struct ComicsApp: App {
    private let environment = AppEnvironment.current

    var body: some Scene {
        WindowGroup {
            if let canvas = environment.launchArgs.canvas {
                // Simulator testing: `-canvas 951x669` renders at the open
                // Duo's inner-screen size (no Duo simulator runtime exists).
                RootView()
                    .frame(width: canvas.width, height: canvas.height)
                    .border(Color.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RootView()
            }
        }
    }
}

/// Reads the window size it is given and derives the layout form from it.
struct RootView: View {
    var body: some View {
        GeometryReader { proxy in
            let form = WindowForm(size: proxy.size)
            Text("Comics")
                .font(.largeTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("windowForm-\(form == .wide ? "wide" : "narrow")")
        }
    }
}
