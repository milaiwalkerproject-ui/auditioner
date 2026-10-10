import Foundation

// Swift mirror of content/schema/catalog.schema.json.
// Honesty contract: a `Verifiable` value is only shown when `status == .verified`.

enum FactStatus: String, Codable, Hashable {
    case verified
    case unverified
    case notApplicable = "not_applicable"
}

struct Verifiable<Value: Codable & Hashable>: Codable, Hashable {
    var status: FactStatus
    var value: Value?
    var source: String?
    var asOf: String?
    var note: String?

    /// The value, but only when it has been verified with a source.
    var verifiedValue: Value? { status == .verified ? value : nil }
    var sourceURL: URL? { source.flatMap(URL.init(string:)) }
    var isHidden: Bool { status == .notApplicable }

    static var unverified: Verifiable<Value> { Verifiable(status: .unverified) }
}

enum Instrument: String, Codable, CaseIterable, Identifiable, Hashable {
    case violin, viola, cello
    case doubleBass = "double-bass"
    case harp, flute, piccolo, oboe
    case englishHorn = "english-horn"
    case clarinet
    case eFlatClarinet = "e-flat-clarinet"
    case bassClarinet = "bass-clarinet"
    case bassoon, contrabassoon, horn, trumpet, trombone
    case bassTrombone = "bass-trombone"
    case tuba, timpani, percussion, keyboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .violin: return String(localized: "Violin")
        case .viola: return String(localized: "Viola")
        case .cello: return String(localized: "Cello")
        case .doubleBass: return String(localized: "Double bass")
        case .harp: return String(localized: "Harp")
        case .flute: return String(localized: "Flute")
        case .piccolo: return String(localized: "Piccolo")
        case .oboe: return String(localized: "Oboe")
        case .englishHorn: return String(localized: "English horn")
        case .clarinet: return String(localized: "Clarinet")
        case .eFlatClarinet: return String(localized: "E♭ clarinet")
        case .bassClarinet: return String(localized: "Bass clarinet")
        case .bassoon: return String(localized: "Bassoon")
        case .contrabassoon: return String(localized: "Contrabassoon")
        case .horn: return String(localized: "Horn")
        case .trumpet: return String(localized: "Trumpet")
        case .trombone: return String(localized: "Trombone")
        case .bassTrombone: return String(localized: "Bass trombone")
        case .tuba: return String(localized: "Tuba")
        case .timpani: return String(localized: "Timpani")
        case .percussion: return String(localized: "Percussion")
        case .keyboard: return String(localized: "Piano / celesta")
        }
    }

    enum Family: String, CaseIterable { case strings, woodwinds, brass, percussion, keyboard }

    var family: Family {
        switch self {
        case .violin, .viola, .cello, .doubleBass, .harp: return .strings
        case .flute, .piccolo, .oboe, .englishHorn, .clarinet, .eFlatClarinet, .bassClarinet, .bassoon, .contrabassoon: return .woodwinds
        case .horn, .trumpet, .trombone, .bassTrombone, .tuba: return .brass
        case .timpani, .percussion: return .percussion
        case .keyboard: return .keyboard
        }
    }

    /// General MIDI program (0-based) used for reference playback.
    var gmProgram: UInt8 {
        switch self {
        case .violin: return 40
        case .viola: return 41
        case .cello: return 42
        case .doubleBass: return 43
        case .harp: return 46
        case .flute: return 73
        case .piccolo: return 72
        case .oboe: return 68
        case .englishHorn: return 69
        case .clarinet, .eFlatClarinet, .bassClarinet: return 71
        case .bassoon, .contrabassoon: return 70
        case .horn: return 60
        case .trumpet: return 56
        case .trombone, .bassTrombone: return 57
        case .tuba: return 58
        case .timpani: return 47
        case .percussion: return 0 // drum kit lives on MIDI channel 10; handled by the player
        case .keyboard: return 0
        }
    }
}

enum Position: String, Codable, CaseIterable, Identifiable, Hashable {
    case principal
    case assistantPrincipal = "assistant-principal"
    case section, utility, second, high, low, concertmaster, any

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .principal: return String(localized: "Principal")
        case .assistantPrincipal: return String(localized: "Assistant principal")
        case .section: return String(localized: "Section")
        case .utility: return String(localized: "Utility")
        case .second: return String(localized: "Second")
        case .high: return String(localized: "High")
        case .low: return String(localized: "Low")
        case .concertmaster: return String(localized: "Concertmaster")
        case .any: return String(localized: "Any")
        }
    }
}

struct BarPoint: Codable, Hashable {
    var bar: Int?
    var mark: String?
    var offset: Int?
    var edge: String?
    var beat: Double?
}

struct ExcerptLocation: Codable, Hashable {
    var text: String
    var start: BarPoint?
    var end: BarPoint?
    var edition: String?
}

struct LocationVariant: Codable, Hashable {
    var location: ExcerptLocation
    var orchestra: String?
    var year: Int?
    var position: Position?
    var source: String
    var asOf: String
}

struct TempoRange: Codable, Hashable {
    var beatUnit: String
    var bpmMin: Double
    var bpmMax: Double
}

enum ContentOrigin: String, Codable, Hashable { case curated, ai }
enum ReviewStatus: String, Codable, Hashable { case draft, approved, rejected }

struct ProseBlock: Codable, Hashable {
    var text: String
    var origin: ContentOrigin
    var reviewStatus: ReviewStatus
    var sources: [String]?
    var model: String?
    var generatedAt: String?
    var reviewedBy: String?
    var reviewedAt: String?

    var isApproved: Bool { reviewStatus == .approved }
}

struct ExcerptProse: Codable, Hashable {
    var history: ProseBlock?
    var technique: ProseBlock?
    var pitfalls: ProseBlock?
    var practiceTips: ProseBlock?
}

struct Difficulty: Codable, Hashable {
    var value: Int
    var origin: ContentOrigin
    var reviewStatus: ReviewStatus
}

enum FrequencyTier: String, Codable, Hashable {
    case core, common, occasional, unknown

    var displayName: String {
        switch self {
        case .core: return String(localized: "Core")
        case .common: return String(localized: "Common")
        case .occasional: return String(localized: "Occasional")
        case .unknown: return String(localized: "Not yet rated")
        }
    }
}

struct FrequencyEvidence: Codable, Hashable {
    var description: String
    var orchestra: String?
    var year: Int?
    var region: String?
    var position: Position?
    var source: String
    var asOf: String
}

struct FrequencyInfo: Codable, Hashable {
    var tier: FrequencyTier?
    var tierStatus: FactStatus?
    var evidence: [FrequencyEvidence]?

    /// Tier shown to users only when verified with evidence.
    var verifiedTier: FrequencyTier? { tierStatus == .verified ? tier : nil }
}

enum RecordingKind: String, Codable, Hashable { case orchestra, solo }
enum RecordingProvider: String, Codable, Hashable { case youtube, appleMusic, hosted, link }

struct Recording: Codable, Hashable, Identifiable {
    var id: String
    var kind: RecordingKind
    var provider: RecordingProvider
    var title: String
    var performer: String?
    var youtubeId: String?
    var isrc: String?
    var url: String?
    var license: String?
    var start: Verifiable<Double>?
    var end: Verifiable<Double>?
    var foundVia: String?
}

enum CopyrightValue: String, Codable, Hashable {
    case publicDomain = "public-domain"
    case protected
}

struct CopyrightInfo: Codable, Hashable {
    var US: Verifiable<CopyrightValue>?
    var EU: Verifiable<CopyrightValue>?
    var CA: Verifiable<CopyrightValue>?
}

struct Movement: Codable, Hashable {
    var number: Int?
    var title: String?
}

struct WorkIds: Codable, Hashable {
    var wikidata: String?
    var imslpPage: String?
    var openOpus: String?
    var musicbrainz: String?

    var imslpURL: URL? {
        guard let page = imslpPage,
              let encoded = page.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://imslp.org/wiki/\(encoded)")
    }
}

enum ListingStatus: String, Codable, Hashable { case draft, inReview = "in_review", published }

struct Excerpt: Codable, Hashable, Identifiable {
    var id: String
    var instrument: Instrument
    var part: String?
    var positions: [Position]
    var composer: String
    var work: String
    var catalogueNumber: String?
    var movement: Movement?
    var title: String
    var workIds: WorkIds?
    var location: Verifiable<ExcerptLocation>
    var variants: [LocationVariant]?
    var tempoMarking: Verifiable<String>?
    var composerMetronome: Verifiable<TempoRange>?
    var typicalTempo: Verifiable<TempoRange>?
    var meter: Verifiable<String>?
    var key: Verifiable<String>?
    var clefs: [String]?
    var soundingTransposition: Int?
    var techniques: [String]?
    var difficulty: Difficulty?
    var frequency: FrequencyInfo?
    var prose: ExcerptProse?
    var recordings: [Recording]?
    var copyright: CopyrightInfo?
    var referenceMusicXML: String?
    var sources: [String]
    var lastVerified: String?
    var listingStatus: ListingStatus
    var provenanceType: String?
    var importedFrom: String?

    /// "Strauss · Don Juan" style heading.
    var workHeading: String {
        let last = composer.split(separator: " ").last.map(String.init) ?? composer
        return "\(last) · \(work)"
    }

    /// Movement + title, e.g. "Mvt. II · Opening".
    var subtitle: String {
        if let m = movement?.number {
            return "Mvt. \(Excerpt.roman(m)) · \(title)"
        }
        return title
    }

    static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n
        var out = ""
        for (value, letters) in table {
            while n >= value { out += letters; n -= value }
        }
        return out
    }
}

struct CatalogFile: Codable {
    var version: String
    var generatedAt: String
    var instrument: Instrument
    var licenseNotes: [String]?
    var excerpts: [Excerpt]
}
