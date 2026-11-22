import Foundation

/// Process-wide configuration shared by the app's views and services.
struct AppEnvironment {
    var launchArgs: LaunchArgs

    static let current = AppEnvironment(launchArgs: LaunchArgs(CommandLine.arguments))
}
