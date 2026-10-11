# Linking Tutti and Auditioner (for Milai and the Tutti project)

Plain words first, then the exact formats. PLAN U1: Tutti helps people *find* an
orchestra and its auditions; Auditioner helps them *win the seat*. In v1 the two
apps link to each other and nothing more — no shared accounts, no shared data.

Two directions:

1. **Tutti → Auditioner.** A Tutti audition card gets a "Prepare in Auditioner"
   button. Tapping it opens Auditioner on the right screen with the details
   already typed in. Auditioner **saves nothing** on its own: the player sees
   the "New audition" form filled in and decides with **Add**.
2. **Auditioner → Tutti.** Settings → About gets a row "Find an orchestra near
   you" that opens Tutti's website inside Auditioner. The row is hidden until
   Tutti's web address is confirmed (see "Turning on the Tutti row" below).

---

## 1. What Tutti sends: the `auditioner://` links

Auditioner registers the URL scheme **`auditioner`** on the device (Info.plist,
`CFBundleURLTypes`). Any app or web page can open such a link; iOS hands it to
Auditioner. If Auditioner isn't installed, the link does nothing — see section 4
for how Tutti should handle that.

Rules that apply to every link:

- Every parameter is **optional**. Leave out what Tutti doesn't know.
- Values are **trimmed** and **cut at 200 characters**.
- **Percent-encode** every value (spaces → `%20`, `/` → `%2F`, `&` → `%26`,
  `?` → `%3F`). The address in `url=` must be fully encoded, otherwise its own
  `&…` parts are read as separate parameters.
- Anything invalid is **ignored silently** (the link still opens; that field is
  simply left blank). Nothing is ever guessed or corrected.
- Parameter names are not case-sensitive (`auditionDate` = `auditiondate`).

### 1a. Open an excerpt page

```
auditioner://excerpt/<excerptId>
```

`<excerptId>` is an id from Auditioner's catalogue
(`content/catalog/*.json` in this repository, field `id`), for example
`cello-beethoven-symphony-5-mvt2` — lower-case words joined by hyphens.

Example (made-up id):

```
auditioner://excerpt/cello-quill-symphony-2-mvt2
```

What Auditioner does: switches to the **Excerpts** tab and opens that excerpt's
page. If the id isn't in the catalogue on the device (older app version, or a
typo) it shows the Excerpts tab with the note "That excerpt isn't in the
catalogue yet."

### 1b. Start a new audition, pre-filled

```
auditioner://audition/new?orchestra=…&position=…&instrument=…&deadline=YYYY-MM-DD&auditionDate=YYYY-MM-DD&url=…
```

| Parameter | What it fills in | Accepted values |
|---|---|---|
| `orchestra` | Orchestra | Any text, up to 200 characters. |
| `position` | Position (e.g. "Section cello") | Any text, up to 200 characters. |
| `instrument` | Instrument picker | One of Auditioner's instrument ids, see list below. Anything else → the player's own instrument from Settings. |
| `deadline` | Application deadline (switches the "Application deadline" toggle on) | A real calendar day written `YYYY-MM-DD`, e.g. `2027-01-15`. `2027-02-30`, `15/01/2027` or `2027-1-5` are ignored. |
| `auditionDate` | Audition day (switches the "Audition day" toggle on) | Same format as `deadline`. |
| `url` | "Link to the official list" | An **https** address only (http, mailto, javascript… are ignored). Percent-encode it. |

Instrument ids (Auditioner's `Instrument` raw values):
`violin`, `viola`, `cello`, `double-bass`, `harp`, `flute`, `piccolo`, `oboe`,
`english-horn`, `clarinet`, `e-flat-clarinet`, `bass-clarinet`, `bassoon`,
`contrabassoon`, `horn`, `trumpet`, `trombone`, `bass-trombone`, `tuba`,
`timpani`, `percussion`, `keyboard`.

Examples (every value is made up — "Example Philharmonic" doesn't exist and the
dates mean nothing):

```
auditioner://audition/new?orchestra=Example%20Philharmonic&position=Section%20cello&instrument=cello&deadline=2027-01-15&auditionDate=2027-03-02&url=https%3A%2F%2Fexample.org%2Fauditions%2Fcello
```

```
auditioner://audition/new?orchestra=Example%20Sinfonietta&instrument=horn
```

```
auditioner://audition/new
```

What Auditioner does: switches to the **Auditions** tab and opens the "New
audition" form with those fields filled in. The player can change anything,
tap **Cancel** (nothing is kept) or **Add** (the audition is saved on the
device, exactly like one typed by hand). The third example simply opens an
empty form.

Things the link cannot do, on purpose: it can't add repertoire lines, notes,
"what the orchestra published", or reminders, and it can't change an existing
audition. Those stay with the player.

---

## 2. Trying a link without Tutti

- **Simulator (Mac):** with the app installed in a running simulator, in
  Terminal: `xcrun simctl openurl booted "auditioner://audition/new?orchestra=Example%20Philharmonic"`
- **iPhone/iPad:** paste the link into Notes, then tap it. Or type it into
  Safari's address bar and confirm "Open in Auditioner".

---

## 3. Turning on the Tutti row in Settings

The row "Find an orchestra near you" (Settings → About) is **hidden** until we
have Tutti's web address. To switch it on, set the constant in
`ios/Auditioner/Core/Routing/DeepLink.swift`:

```swift
enum TuttiLink {
    static let findOrchestraURL: URL? = URL(string: "https://<tutti's address>")
}
```

Only an https address works; the page opens in the in-app Safari view, the
same one used for IMSLP links. Nothing else needs to change.

---

## 4. Why not a normal `https://…` link (universal link)?

An `https://auditioner.example/excerpt/…` link that opens the app when it's
installed and a web page when it isn't is called a **universal link**. It needs
a **website domain we own** that serves a small file
(`/.well-known/apple-app-site-association`) naming the app's bundle id and team.
We don't have a domain yet, so v1 uses the custom scheme above. The custom
scheme has two limits Tutti should know about:

- If Auditioner isn't installed, the link does nothing (on iOS, Safari shows
  "Safari cannot open the page"). Tutti should check first — on iOS,
  `UIApplication.shared.canOpenURL(URL(string: "auditioner://")!)` with
  `auditioner` listed under `LSApplicationQueriesSchemes` in Tutti's
  Info.plist — and otherwise send the person to Auditioner's App Store page.
- On the web, there's no way to tell whether the tap worked.

When we have a domain, universal links can be added without changing the link
contents: the paths stay `/excerpt/<id>` and `/audition/new?…`.

---

## 5. Privacy

A link is read once, on the device, and then forgotten. Auditioner stores
nothing from it until the player taps **Add**, and it never sends the link's
contents anywhere. Opening Tutti's website from Settings is an ordinary web
visit inside the app (Apple's in-app Safari view); Tutti sees it as a visit
from Safari, with nothing from Auditioner attached.
