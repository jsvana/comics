import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings: hover text, the catalog source, the image cache, progress export/import and iCloud.
struct SettingsView: View {
    let model: LibraryModel

    @AppStorage("hoverTapToReveal") private var hoverTapToReveal = false
    @State private var urlText = ""
    @State private var catalogMessage: String?
    @State private var refreshingCatalog = false
    @State private var cacheBytes: Int?
    @State private var progressMessage: String?
    @State private var exported: SharedFile?
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    private var env: AppEnvironment { model.env }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    Picker("Hover text", selection: $hoverTapToReveal) {
                        Text("Show").tag(false)
                        Text("Tap to reveal").tag(true)
                    }
                    .accessibilityIdentifier("settings-hover")
                }
                catalogSection
                cacheSection
                progressSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings-done")
                }
            }
        }
        .onAppear { urlText = env.catalog.remote.absoluteString }
        .task { cacheBytes = await env.images.totalBytes() }
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { await importProgress(url) }
            case .failure: progressMessage = "Couldn't open that file."
            }
        }
    }

    // MARK: Catalog

    private var catalogSection: some View {
        Section {
            TextField("Catalog address", text: $urlText, axis: .vertical)
                .font(.footnote)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { applyURL() }
                .accessibilityIdentifier("settings-catalog-url")
            Button {
                Task { await refreshCatalog() }
            } label: {
                HStack {
                    Text("Refresh catalog now")
                    Spacer()
                    if refreshingCatalog { ProgressView() }
                }
            }
            .disabled(refreshingCatalog)
            .accessibilityIdentifier("settings-refresh-catalog")
            LabeledContent("Catalog version", value: "\(env.catalog.catalog.version)")
            if let catalogMessage {
                Text(catalogMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Catalog")
        } footer: {
            Text("The list of comics and how to read them. It is checked once a day.")
        }
    }

    /// Saves the typed address; an empty field goes back to the default. Returns false if invalid.
    @discardableResult
    private func applyURL() -> Bool {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: CatalogStore.remoteDefaultsKey)
            env.catalog.remote = CatalogStore.defaultRemote
            urlText = CatalogStore.defaultRemote.absoluteString
            return true
        }
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            catalogMessage = "That isn't a web address."
            return false
        }
        if url == CatalogStore.defaultRemote {
            UserDefaults.standard.removeObject(forKey: CatalogStore.remoteDefaultsKey)
        } else {
            UserDefaults.standard.set(url.absoluteString, forKey: CatalogStore.remoteDefaultsKey)
        }
        env.catalog.remote = url
        return true
    }

    private func refreshCatalog() async {
        guard applyURL() else { return }
        refreshingCatalog = true
        defer { refreshingCatalog = false }
        let before = env.catalog.catalog.version
        switch await env.refreshCatalog(force: true) {
        case .adopted:
            let now = env.catalog.catalog.version
            catalogMessage = now == before ? "Up to date (version \(now))." : "Updated to version \(now)."
        case .rejected:
            catalogMessage = "The catalog there is older or not one this app can read. Keeping version \(before)."
        case .failed:
            catalogMessage = "No catalog found at that address. Keeping version \(before)."
        case .notDue:
            catalogMessage = "The catalog isn't fetched in test mode."
        }
    }

    // MARK: Image cache

    private var cacheSection: some View {
        Section {
            LabeledContent("Size", value: cacheBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                .accessibilityIdentifier("settings-cache-size")
            Button("Clear image cache", role: .destructive) {
                Task {
                    await env.images.clear()
                    cacheBytes = await env.images.totalBytes()
                }
            }
            .accessibilityIdentifier("settings-clear-cache")
        } header: {
            Text("Image cache")
        } footer: {
            Text("Strip images are kept for offline reading, up to 500 MB. Cleared images download again when needed.")
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        Section {
            Button("Export progress…") { Task { await exportProgress() } }
                .accessibilityIdentifier("settings-export")
            Button("Import progress…") { importing = true }
                .accessibilityIdentifier("settings-import")
            if let progressMessage {
                Text(progressMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Your place")
        } footer: {
            Text(iCloudStatus)
                .accessibilityIdentifier("settings-icloud")
        }
    }

    private var iCloudStatus: String {
        if !env.usesICloud {
            return "iCloud copy is off for this launch. Export progress to keep a copy."
        }
        if FileManager.default.ubiquityIdentityToken == nil {
            return "Not signed in to iCloud: your place is kept on this phone only. Export progress to keep a copy."
        }
        return "Your place in each comic is copied to iCloud, so a new phone or a reinstall can pick it up."
    }

    private func exportProgress() async {
        let library = env.library
        let places = env.places
        do {
            let url = try await Task.detached {
                let data = try ProgressFile.export(library: library, places: places)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Comics progress.json")
                try data.write(to: url, options: .atomic)
                return url
            }.value
            exported = SharedFile(url: url)
        } catch {
            progressMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func importProgress(_ url: URL) async {
        let library = env.library
        let places = env.places
        let catalog = env.catalog.catalog
        progressMessage = "Importing…"
        do {
            let failed = try await Task.detached { () -> [String] in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                return try await ProgressFile.apply(data, catalog: catalog, library: library, places: places)
            }.value
            if failed.isEmpty {
                progressMessage = "Progress imported."
            } else {
                let names = failed.map { id in catalog.comics.first { $0.id == id }?.title ?? id }
                progressMessage = "Imported, except: \(names.formatted(.list(type: .and))). "
                    + "They couldn't be restored (no connection, or no longer in the catalog). Try importing again later."
            }
        } catch {
            progressMessage = "That isn't a Comics progress file."
        }
        await model.reload()
    }
}

/// A file handed to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// `UIActivityViewController` for the export.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
