import SwiftUI

/// Settings → About → Privacy: a short, plain-words summary. The full policy comes with M5.
struct PrivacyView: View {
    private static let youtubeTerms: URL? = URL(string: "https://www.youtube.com/t/terms")
    private static let googlePrivacy: URL? = URL(string: "https://policies.google.com/privacy")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PrivacyBlock(symbol: "person.crop.circle.badge.xmark",
                             title: String(localized: "No account needed"),
                             text: String(localized: "You don't have to sign in. Your instrument, position, region, parts, markings, reference audio and practice recordings stay on this device. The microphone is used only while you record, and the recordings are never uploaded."))
                PrivacyBlock(symbol: "apple.logo",
                             title: String(localized: "If you sign in with Apple"),
                             text: String(localized: "Signing in is optional and only raises your daily scan limit. We don't ask Apple for your name or email. Our server keeps a scrambled code for your Apple ID, an encrypted key that lets us disconnect Apple when you delete the account, and the date you joined. Delete account in Settings removes all of it from our server and disconnects Apple; nothing on this device is touched."))
                PrivacyBlock(symbol: "doc.viewfinder",
                             title: String(localized: "Scans"),
                             text: String(localized: "When you ask the app to read the notes on a page, the part you marked is sent to the Auditioner server, used only to read the notes, and deleted right after — within 24 hours at the latest. You're asked before the first time. The app also sends a random number for this install so the server can limit scans per device; it doesn't identify you."))
                PrivacyBlock(symbol: "nosign",
                             title: String(localized: "Nothing sent to AI"),
                             text: String(localized: "Your scans, parts and recordings are never sent to any AI service."))
                PrivacyBlock(symbol: "exclamationmark.bubble",
                             title: String(localized: "Feedback you send"),
                             text: String(localized: "There's no public email: Send feedback and Report an error are how you reach us. A message carries your words, where in the app it came from, the excerpt, the app version and a scrambled install code — never your name, email or device. It's stored by our database provider (Supabase, in the US) until we've handled it, at most 12 months, and read by people, never by an AI service. If the server can't be reached it waits on this device."))
                PrivacyBlock(symbol: "person.3",
                             title: String(localized: "Popular with other players"),
                             text: String(localized: "Off unless you turn it on, and for players 18 and older. Then, once a week, the app sends your instrument, the week and which catalogue excerpts you practised — no name, recordings, notes or scans — under a scrambled install code. Shown only when at least 20 players share, as tiers, never numbers. Turning it off deletes what you shared."))
                PrivacyBlock(symbol: "play.rectangle",
                             title: String(localized: "YouTube videos"),
                             text: String(localized: "Recordings on excerpt pages are played by YouTube's own player, under YouTube's terms of service and Google's privacy policy. The app doesn't download or change the videos."))
                VStack(alignment: .leading, spacing: 8) {
                    if let url = PrivacyView.youtubeTerms {
                        Link(destination: url) {
                            Label("YouTube terms of service", systemImage: "arrow.up.right.square")
                        }
                    }
                    if let url = PrivacyView.googlePrivacy {
                        Link(destination: url) {
                            Label("Google privacy policy", systemImage: "arrow.up.right.square")
                        }
                    }
                }
                .font(.subheadline)
                .padding(.leading, 42)
                Text("A full privacy policy comes before the App Store release.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyBlock: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Theme.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }
}
