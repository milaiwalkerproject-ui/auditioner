import SwiftUI

/// A licence text shipped in Resources/Licenses (flattened into the bundle root).
struct LicenceFile: Identifiable, Hashable {
    let id: String
    let title: String
    let resourceName: String

    static let bundled: [LicenceFile] = [
        LicenceFile(id: "generaluser-gs",
                    title: String(localized: "GeneralUser GS (instrument sounds)"),
                    resourceName: "GeneralUser-GS-LICENSE"),
        LicenceFile(id: "verovio",
                    title: String(localized: "Verovio (music engraving)"),
                    resourceName: "Verovio-LGPL-3.0"),
    ]

    /// The licence text, or `nil` when the file isn't in the bundle.
    func text(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Catalogue files repeat the same note; show each distinct note once, in order.
    static func uniqueNotes(_ notes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for note in notes {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// First line of a note, for the row label.
    static func headline(of note: String) -> String {
        let firstLine = note.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? note
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 80 {
            let index = trimmed.index(trimmed.startIndex, offsetBy: 80)
            return String(trimmed[..<index]) + "…"
        }
        return trimmed
    }
}

/// Settings → About → Licences.
struct LicencesView: View {
    @EnvironmentObject private var catalog: CatalogStore

    private var notes: [String] {
        LicenceFile.uniqueNotes(catalog.licenseNotes)
    }

    var body: some View {
        List {
            Section {
                ForEach(LicenceFile.bundled) { file in
                    NavigationLink {
                        LicenceTextView(title: file.title,
                                        text: file.text() ?? String(localized: "The licence text is missing from this build."))
                    } label: {
                        Text(file.title)
                    }
                }
            } header: {
                Text("Sounds and notation")
            } footer: {
                Text("Instrument sounds come from the GeneralUser GS SoundFont. Notation is drawn by Verovio, used under the LGPL 3.0; the app links it as a separate component and you can replace it.")
            }

            if !notes.isEmpty {
                Section {
                    ForEach(Array(notes.enumerated()), id: \.offset) { entry in
                        NavigationLink {
                            LicenceTextView(title: String(localized: "Catalogue data"), text: entry.element)
                        } label: {
                            Text(LicenceFile.headline(of: entry.element))
                                .lineLimit(2)
                        }
                    }
                } header: {
                    Text("Catalogue data")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenceTextView: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
