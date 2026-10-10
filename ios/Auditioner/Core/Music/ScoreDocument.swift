import Foundation

/// Value type handed to the practice player: MusicXML plus what we know about it.
struct ScoreDocument: Identifiable, Hashable {
    var id: UUID
    var title: String
    var musicXML: String
    var origin: ScoreOrigin
    var instrument: Instrument
    var excerptId: String?
    var preferredBPM: Double?
    var warnings: [String]

    init(id: UUID = UUID(), title: String, musicXML: String, origin: ScoreOrigin, instrument: Instrument,
         excerptId: String? = nil, preferredBPM: Double? = nil, warnings: [String] = []) {
        self.id = id
        self.title = title
        self.musicXML = musicXML
        self.origin = origin
        self.instrument = instrument
        self.excerptId = excerptId
        self.preferredBPM = preferredBPM
        self.warnings = warnings
    }

    /// Loads a bundled MusicXML resource by file name (e.g. "demo-d-major-scale.musicxml").
    static func bundled(named fileName: String, title: String, origin: ScoreOrigin, instrument: Instrument,
                        excerptId: String? = nil, bundle: Bundle = .main) -> ScoreDocument? {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext.isEmpty ? "musicxml" : ext),
              let xml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ScoreDocument(title: title, musicXML: xml, origin: origin, instrument: instrument, excerptId: excerptId)
    }

    static func demoScale() -> ScoreDocument? {
        bundled(named: "demo-d-major-scale.musicxml", title: String(localized: "Demo: D major scale"), origin: .demo, instrument: .cello)
    }
}
