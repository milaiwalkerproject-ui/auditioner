import SwiftUI
import SwiftData

/// New audition, or edit the details of one. Dates are optional: nothing is guessed.
struct AuditionFormView: View {
    enum Mode {
        case create
        case edit(Audition)
    }

    let mode: Mode
    let onSaved: (Audition) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var orchestra: String
    @State private var position: String
    @State private var instrumentRaw: String
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var hasAuditionDate: Bool
    @State private var auditionDate: Date
    @State private var completeness: ListCompleteness
    @State private var sourceURL: String
    @State private var notes: String

    /// `prefill` (create only) fills the fields in from an `auditioner://audition/new` link (PLAN U1);
    /// the player still has to tap Add, so nothing is saved by the link itself.
    init(mode: Mode, prefill: AuditionPrefill? = nil, onSaved: @escaping (Audition) -> Void) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .create:
            let given: AuditionPrefill = prefill ?? AuditionPrefill()
            let instrument: Instrument = given.instrument ?? AppSettings.shared.instrument
            _orchestra = State(initialValue: given.orchestra)
            _position = State(initialValue: given.position)
            _instrumentRaw = State(initialValue: instrument.rawValue)
            _hasDeadline = State(initialValue: given.deadline != nil)
            _deadline = State(initialValue: given.deadline ?? Date())
            _hasAuditionDate = State(initialValue: given.auditionDate != nil)
            _auditionDate = State(initialValue: given.auditionDate ?? Date())
            _completeness = State(initialValue: .unknown)
            _sourceURL = State(initialValue: given.sourceURL ?? "")
            _notes = State(initialValue: "")
        case .edit(let audition):
            _orchestra = State(initialValue: audition.orchestra)
            _position = State(initialValue: audition.position)
            _instrumentRaw = State(initialValue: audition.instrumentRaw)
            _hasDeadline = State(initialValue: audition.applicationDeadline != nil)
            _deadline = State(initialValue: audition.applicationDeadline ?? Date())
            _hasAuditionDate = State(initialValue: audition.auditionDate != nil)
            _auditionDate = State(initialValue: audition.auditionDate ?? Date())
            _completeness = State(initialValue: ListCompleteness(raw: audition.listCompleteness))
            _sourceURL = State(initialValue: audition.sourceURL ?? "")
            _notes = State(initialValue: audition.notes)
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var canSave: Bool {
        !orchestra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var screenTitle: String {
        isCreating ? String(localized: "New audition") : String(localized: "Edit audition")
    }

    private var saveTitle: String {
        isCreating ? String(localized: "Add") : String(localized: "Save")
    }

    var body: some View {
        Form {
            whoSection
            datesSection
            listSection
            notesSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) { save() }
                    .disabled(!canSave)
            }
        }
    }

    // MARK: Sections

    private var whoSection: some View {
        Section {
            TextField("Orchestra", text: $orchestra)
            TextField("Position, e.g. Section cello", text: $position)
            Picker(selection: $instrumentRaw) {
                ForEach(Instrument.allCases) { instrument in
                    Text(instrument.displayName).tag(instrument.rawValue)
                }
            } label: {
                Text("Instrument")
            }
        } header: {
            Text("Audition")
        }
    }

    private var datesSection: some View {
        Section {
            Toggle("Application deadline", isOn: $hasDeadline)
            if hasDeadline {
                DatePicker("Deadline", selection: $deadline, displayedComponents: .date)
            }
            Toggle("Audition day", isOn: $hasAuditionDate)
            if hasAuditionDate {
                DatePicker("Audition", selection: $auditionDate, displayedComponents: .date)
            }
        } header: {
            Text("Dates")
        } footer: {
            Text("Leave a date off if the orchestra hasn't announced it. Reminders use these dates.")
        }
    }

    private var listSection: some View {
        Section {
            Picker(selection: $completeness) {
                ForEach(ListCompleteness.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            } label: {
                Text("What the orchestra published")
            }
            TextField("Link to the official list (https://…)", text: $sourceURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("The list")
        } footer: {
            Text("Only a web address is kept. The orchestra's file itself is never stored by the app.")
        }
    }

    private var notesSection: some View {
        Section {
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text("Notes")
        }
    }

    // MARK: Save

    private func save() {
        let cleanedOrchestra: String = orchestra.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPosition: String = position.trimmingCharacters(in: .whitespacesAndNewlines)
        let instrument: Instrument = Instrument(rawValue: instrumentRaw) ?? .cello
        let audition: Audition
        switch mode {
        case .create:
            audition = Audition(orchestra: cleanedOrchestra, position: cleanedPosition, instrument: instrument)
            modelContext.insert(audition)
        case .edit(let existing):
            audition = existing
            audition.orchestra = cleanedOrchestra
            audition.position = cleanedPosition
            audition.instrumentRaw = instrument.rawValue
        }
        let calendar: Calendar = Calendar.current
        audition.applicationDeadline = hasDeadline ? AuditionDates.noon(of: deadline, calendar: calendar) : nil
        audition.auditionDate = hasAuditionDate ? AuditionDates.noon(of: auditionDate, calendar: calendar) : nil
        audition.listCompleteness = completeness.rawValue
        audition.sourceURL = AuditionFormLogic.cleanedSourceURL(sourceURL)
        audition.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        AuditionsStore.save(modelContext)
        if audition.remindersEnabled {
            Task {
                await AuditionReminderCenter.shared.reschedule(for: audition)
            }
        }
        onSaved(audition)
        dismiss()
    }
}

/// Pure checks for the form (unit-tested).
enum AuditionFormLogic {
    /// Keeps only http(s) addresses; anything else becomes `nil` so no junk is stored or opened.
    static func cleanedSourceURL(_ text: String) -> String? {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return nil }
        return trimmed
    }
}
