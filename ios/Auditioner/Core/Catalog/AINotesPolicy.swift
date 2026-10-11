import Foundation
import Combine
import StoreKit

// PLAN A6: Hong Kong and Macau get the app, but AI-written notes are hidden there. "AI-written" is
// every note whose origin is `ai` and every machine translation (a translation is AI prose too, even
// of a note a person wrote). Curated notes still show, in English. Where it applies, the notes
// section says once: "Some notes aren't available in your region."

/// The pure rule. The App Store storefront decides (that is where the player gets the app); only
/// when it is unknown — no StoreKit answer, as in the simulator — does the device's region decide.
enum AINotesPolicy {
    /// Storefront countries, ISO 3166-1 alpha-3 as StoreKit reports them (`Storefront.countryCode`).
    static let hiddenStorefronts: Set<String> = ["HKG", "MAC"]
    /// Device regions, ISO 3166-1 alpha-2 as `Locale.region` reports them.
    static let hiddenRegions: Set<String> = ["HK", "MO"]

    /// True when AI notes are hidden. A known storefront outside Hong Kong / Macau shows them whatever
    /// the device region says; an empty or whitespace code counts as unknown; case doesn't matter.
    static func hidesAINotes(storefrontCountry: String?, localeRegion: String?) -> Bool {
        if let storefront: String = normalized(storefrontCountry) {
            return hiddenStorefronts.contains(storefront)
        }
        if let region: String = normalized(localeRegion) {
            return hiddenRegions.contains(region)
        }
        return false
    }

    private static func normalized(_ code: String?) -> String? {
        guard let code: String = code else { return nil }
        let trimmed: String = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Where this device stands under `AINotesPolicy`. The device region is known at once; the storefront
/// is read once at launch (`load()`, StoreKit 2) and the answer kept for the whole run. Views hold it
/// like the other singletons: `@ObservedObject private var aiNotes: AINotesAvailability = AINotesAvailability.shared`.
@MainActor
final class AINotesAvailability: ObservableObject {
    static let shared: AINotesAvailability = AINotesAvailability()

    @Published private(set) var hidesAINotes: Bool
    /// What StoreKit answered, once it has (nil before `load()` and when StoreKit has no storefront).
    private(set) var storefrontCountry: String? = nil
    private let localeRegion: String?
    private var didLoad: Bool = false

    init(localeRegion: String? = Locale.current.region?.identifier) {
        self.localeRegion = localeRegion
        self.hidesAINotes = AINotesPolicy.hidesAINotes(storefrontCountry: nil, localeRegion: localeRegion)
    }

    /// Reads the App Store storefront once (`AuditionerApp` calls this at launch). Later calls do nothing.
    func load() async {
        guard !didLoad else { return }
        didLoad = true
        let storefront: Storefront? = await Storefront.current
        apply(storefrontCountry: storefront?.countryCode)
    }

    /// Applies a storefront answer (what `load()` does with StoreKit's; tests call it directly).
    func apply(storefrontCountry: String?) {
        self.storefrontCountry = storefrontCountry
        hidesAINotes = AINotesPolicy.hidesAINotes(storefrontCountry: storefrontCountry, localeRegion: localeRegion)
    }
}
