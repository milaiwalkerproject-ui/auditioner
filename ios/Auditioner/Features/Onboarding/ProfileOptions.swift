import Foundation

/// Choices offered in onboarding and Settings. Pure data, unit-tested.
enum ProfileOptions {

    // MARK: Regions

    struct Region: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let defaultRegionId: String = "north-america"

    /// Stored under `SettingsKey.region` by id.
    static let regions: [Region] = [
        Region(id: "north-america", name: String(localized: "North America")),
        Region(id: "europe-german", name: String(localized: "Europe (German-speaking)")),
        Region(id: "europe-other", name: String(localized: "Europe (other)")),
        Region(id: "uk", name: String(localized: "UK")),
        Region(id: "asia-pacific", name: String(localized: "Asia-Pacific")),
        Region(id: "other", name: String(localized: "Other")),
    ]

    static func regionName(id: String) -> String {
        regions.first(where: { $0.id == id })?.name ?? regions[0].name
    }

    // MARK: Positions

    /// Chairs that make sense for the instrument: the common five, plus High/Low for horn
    /// and Concertmaster for violin.
    static func positions(for instrument: Instrument) -> [Position] {
        var list: [Position] = [.principal, .assistantPrincipal, .section, .utility, .second]
        switch instrument {
        case .horn:
            list.append(contentsOf: [.high, .low])
        case .violin:
            list.insert(.concertmaster, at: 0)
        default:
            break
        }
        return list
    }

    /// The stored position, or Section when it doesn't fit the instrument.
    static func validPosition(_ raw: String, for instrument: Instrument) -> Position {
        let allowed = positions(for: instrument)
        if let position = Position(rawValue: raw), allowed.contains(position) {
            return position
        }
        return .section
    }

    // MARK: Instruments

    static func familyName(_ family: Instrument.Family) -> String {
        switch family {
        case .strings: return String(localized: "Strings")
        case .woodwinds: return String(localized: "Woodwinds")
        case .brass: return String(localized: "Brass")
        case .percussion: return String(localized: "Timpani and percussion")
        case .keyboard: return String(localized: "Keyboard")
        }
    }

    static func instruments(in family: Instrument.Family) -> [Instrument] {
        Instrument.allCases.filter { $0.family == family }
    }

    // MARK: Tuning

    /// A4 choices offered in Settings, in hertz.
    static let tunings: [Double] = [440, 441, 442, 443]
}
