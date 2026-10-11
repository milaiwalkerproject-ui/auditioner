import SwiftUI

/// "How is this worked out?" — the rules behind "Most asked for your chair", in plain words.
struct RecommendationInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(RecommendationInfoCopy.paragraphs) { paragraph in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(paragraph.title)
                                .font(.headline)
                                .foregroundStyle(Theme.ink)
                            Text(paragraph.text)
                                .font(.body)
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("How is this worked out?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The sheet's text, kept as data so it can be checked in tests and translated later.
enum RecommendationInfoCopy {
    struct Paragraph: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    static var paragraphs: [Paragraph] {
        [
            Paragraph(id: "lists",
                      title: String(localized: "Which lists"),
                      text: String(localized: "The repertoire lists orchestras publish for their own auditions. Each list counts once, however many of its excerpts are in the catalogue. We count lists for your instrument and chair, plus lists marked as for any chair. Include all chairs also counts principal, assistant and section lists together, and lists that don't say which chair they were for.")),
            Paragraph(id: "recency",
                      title: String(localized: "Recent lists count more"),
                      text: String(localized: "A list from this year counts as 1, one from three years ago as a half, six years ago as a quarter, and so on. A list without a date counts like the oldest one we have.")),
            Paragraph(id: "share",
                      title: String(localized: "The share and the tiers"),
                      text: String(localized: "The share is the weight of the lists that include the excerpt divided by the weight of all the lists. Core means at least half, Common at least a fifth, Occasional below that.")),
            Paragraph(id: "minimum",
                      title: String(localized: "The 5-list minimum"),
                      text: String(localized: "We name a tier only once we have at least \(LocalRecommendationEngine.minimumLists) lists. With fewer we show the plain count and say so.")),
            Paragraph(id: "region",
                      title: String(localized: "Your region"),
                      text: String(localized: "Lists from your region come first. When we have fewer than \(LocalRecommendationEngine.minimumLists) from there, we say so and count every region.")),
            Paragraph(id: "sources",
                      title: String(localized: "Check it yourself"),
                      text: String(localized: "Each excerpt page lists every source we counted for it, with a link to the orchestra's own page.")),
            Paragraph(id: "server",
                      title: String(localized: "Server or catalogue"),
                      text: String(localized: "When the app can reach our server, this list uses the orchestra lists reviewed there, which are more and newer. Otherwise it uses the lists cited in the app's catalogue. The line under the list says which. Each excerpt page always counts the catalogue's lists, so its number matches the sources shown under it.")),
            Paragraph(id: "open-now",
                      title: String(localized: "On N open auditions now"),
                      text: String(localized: "A separate badge: how many auditions open right now list the excerpt. It appears only when the server can be reached, and never changes the share.")),
        ]
    }
}
