import SwiftUI

/// "Add comics": the catalog, with Add (start from the first strip or the latest), index-building
/// progress, and a tick for comics already in the library. Closing the sheet does not stop an add.
struct CatalogView: View {
    let model: LibraryModel

    @State private var pending: ComicDef?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.env.catalog.catalog.comics) { def in
                row(def)
            }
            .navigationTitle("Add comics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("catalog-done")
                }
            }
        }
        .confirmationDialog(pending.map { "Add \($0.title)" } ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { def in
            Button("Start from the first strip") { model.add(def, start: .first) }
            Button("Start from the latest") { model.add(def, start: .latest) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ def: ComicDef) -> some View {
        let stored = model.rows[def.id]
        let inLibrary = stored.map { !$0.removed } ?? false
        let adding = model.adding[def.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(def.title)
                    .font(.headline)
                Spacer()
                trailing(def, inLibrary: inLibrary, removed: stored?.removed ?? false, adding: adding)
            }
            Text(def.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(def.about)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            if let stored, stored.count > 0 {
                Text(stored.count == 1 ? "1 strip" : "\(stored.count.formatted()) strips")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let adding {
                HStack(spacing: 10) {
                    if let progress = adding.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView(value: nil as Double?)
                    }
                    Text(adding.cancelling ? "Cancelling…" : "Building the strip list…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.top, 4)
                .accessibilityIdentifier("adding-\(def.id)")
            }
            if let error = model.addErrors[def.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func trailing(_ def: ComicDef, inLibrary: Bool, removed: Bool, adding: LibraryModel.AddState?) -> some View {
        if inLibrary {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel("In your library")
                .accessibilityIdentifier("added-\(def.id)")
        } else if adding != nil {
            Button("Cancel") { model.cancelAdd(def.id) }
                .buttonStyle(.borderless)
                .disabled(adding?.cancelling ?? false)
                .accessibilityIdentifier("cancel-\(def.id)")
        } else if removed {
            // Removed less than 30 days ago: adding it back keeps the old place.
            Button("Add back") { model.add(def, start: .first) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("add-\(def.id)")
        } else {
            Button("Add") { pending = def }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("add-\(def.id)")
        }
    }
}
