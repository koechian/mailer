# Mailer

[![Build and test](https://github.com/koechian/mailer/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/koechian/mailer/actions/workflows/build-and-test.yml)

A fast, private mail app for the Mac. Native SwiftUI, with no server in between: each account
talks straight to its provider, and your mail is kept in a small database on your Mac, so
opening, switching and searching never wait on the network. Gmail today; iCloud and Microsoft
are next.

Mailer is a fork of [Postline](https://github.com/oiharshit/postline) by Harshit Maurya, taken
in its own direction: more providers, mail sorted before you see it, and AI that works with
your mail without taking it anywhere you didn't choose.

Needs macOS 15 or later on an Apple silicon Mac.

## What it does

- **Fast.** Mail is read from the database on your Mac: a mailbox of 2,000 messages lists in
  about 3 ms and a search takes about 4 ms. An email's text shows as soon as it is laid out;
  its images fill in afterwards, each with a placeholder while it loads. New mail shows up
  within about 5 s of landing in Gmail (a history check every 5 s beside an IMAP IDLE
  connection, because Gmail's IDLE pings were measured arriving 7–47 s late).
- **Inbox and Other.** Inbox is Gmail's Primary tab, as Gmail reports it. When Gmail has no
  answer (its Primary search comes back empty when Inbox tabs are off), each email is sorted by
  its own category: Promotions, Social and Forums go to **Other**.
- **Private by default.** Email loads in full with its tracking pixels removed first, so most
  senders can't tell when you opened it. Scripts never run and an email can't redirect the
  reader. No analytics; error and crash reporting is off unless you turn it on. See
  [Privacy](#privacy).
- **Export for AI.** **⇧⌘E** (or ⋯ → Export for AI…) turns a thread into one clean Markdown
  document for an AI assistant: each message once, oldest first, with sender, time and
  recipients, and you marked "(me)". Quoted replies, reply headers, signatures, "Sent from my
  iPhone" and confidentiality notices are taken out, and so is hidden text, which a sender could
  use to slip instructions to an AI that you never saw. Images can be saved alongside in a
  folder; addresses are left out unless you ask. A preview shows exactly what will be handed
  over.
- **Writing help, on your Mac only.** Three faint suggested replies under each email from a
  person, ghost text while you write (**Tab** or **→** takes it), and grammar fixes on
  sentences you've finished (⌘Z undoes). Suggestions never add a number (time, date, amount)
  that isn't already in the email or your draft.
- **Sign-in codes.** A code gets its own notification with the code as the title and a
  **Copy code** button. Click any notification to open that email.
- **Swipe and batch.** Two-finger swipe right to archive, left to Trash. **⌘-click**,
  **⇧-click** or **⌘A** to pick several, then archive, delete or mark them read together.
  Everything can be undone with ⌘Z.
- **Several accounts**, one Inbox or one at a time. Real photos from Google Contacts and
  initials as a fallback; company logos if you turn them on. A signed-out account says so in
  Settings, with **Sign in again**.
- **Send as any address** Gmail lets you send as, with 5 seconds to Undo.
- **Starts empty.** Only mail that arrives after you connect is downloaded. Import older mail
  (7 days, 30 days, 3 months, 1 year or everything) at sign-in or later in Settings.
- **Updates itself.** Every change merged to `main` is built, signed and published on
  GitHub; Mailer checks every hour, downloads a new version in the background and installs
  it when you quit. The header says when one is ready, with **Restart** to install it now.
  **Mailer → Check for Updates…** checks straight away.
- **In the Dock like any other app.** Closing the window keeps Mailer running, so mail and
  codes still arrive; a menu bar icon appears for 5 minutes when new Primary mail or a code
  arrives.

## Roadmap

Where Mailer is going, roughly in order:

1. **More providers.** iCloud next, over IMAP with an app-specific password, then Microsoft
   (Outlook and Microsoft 365, through Microsoft Graph). The database already stores mail in a
   provider-neutral form (mailboxes, read and pinned state, tags, and Mailer's own message IDs
   beside each provider's), so each provider plugs in behind one interface.
2. **A smart inbox.** Mail sorted before you see it: your own rules first, then a model
   reading and filing what the rules don't cover, kept as tags you can see and change.
3. **An AI layer.** One interface for the writing and sorting models, on your Mac by default,
   with cloud models such as Claude opted into feature by feature. On top of it, assistant
   actions over your mail, and a local MCP server so AI tools on your Mac can search and read
   mail with your say-so.
4. **Images inside Mailer.** Attachments and images previewed in the app instead of in
   Preview.
5. **Speed, measured.** Every change to a hot path is timed before and after (see
   [Measuring performance](#measuring-performance)). Next: keeping a web view ready, so the
   first email after launch opens as fast as the rest.
6. **Its own identity.** Mailer still uses Postline's app ID and data folders, so existing
   sign-ins and mail carried over; moving to its own needs a one-time move of both.

## Install

Download `Mailer-<version>.zip` from the
[latest release](https://github.com/koechian/mailer/releases/latest), unzip it and move
Mailer to Applications. It isn't notarised, so the first time, right-click it and choose
**Open**. Mailer asks for the client ID of your own free Google project
([Google setup](#google-setup-once-free-about-10-minutes)); from then on it updates itself.

Or build it yourself (below).

## Build it yourself

You need Xcode 26 or later (the build and CI use 26.6) and the Metal Toolchain for the writing
model:

```bash
xcodebuild -downloadComponent MetalToolchain   # once (or Xcode → Settings → Components)

git clone https://github.com/koechian/mailer.git
cd mailer
./build.sh demo       # try it with sample mail, no account needed
```

To use your own mail, do the Google setup below once, then:

```bash
echo "YOUR-CLIENT-ID.apps.googleusercontent.com" > GoogleClientID.txt
./build.sh install    # builds, copies to /Applications and opens it
```

| Command | What it does |
|---|---|
| `./build.sh` | builds `build/Mailer.app` |
| `./build.sh run` | builds and launches it |
| `./build.sh demo` | launches with sample mail in a separate database |
| `./build.sh install` | copies it to /Applications and opens it (quits the running copy first) |
| `./build.sh release` | makes a notarized `build/Mailer.dmg` (Developer ID needed) |
| `swift test` | runs the tests: parsing, database and migration, Gmail mapping, outgoing mail, code detection, writing help, menu bar timing, remote content and tracking pixels, export for AI |

The app is signed with your Apple Development certificate if you have one (add a free Apple
ID in Xcode → Settings → Accounts, then Manage Certificates → + → Apple Development),
otherwise ad hoc. Ad hoc works too; macOS just asks again for Keychain access after each
rebuild. If your certificate shows as not valid, install Apple's
[WWDR G3 intermediate certificate](https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer).

Every push to `main` and every pull request is built and tested on GitHub
(`.github/workflows/build-and-test.yml`).

### Updates

The version is `1.2.<commits on main>`, set by `build.sh`, so a local build and the published
build of the same commit are the same version. Each merge to `main` is published as a GitHub
release: `tools/package_release.sh` zips the app, signs the zip with the update key and writes
`appcast.xml`, the feed Mailer reads through [Sparkle](https://sparkle-project.org). Releases
need three repository secrets:

| Secret | What it is |
|---|---|
| `SIGNING_CERTIFICATE_P12` | Your Apple Development certificate and key, exported as .p12, base64. The same one your own builds use, so the Keychain keeps trusting updated copies. |
| `SIGNING_CERTIFICATE_PASSWORD` | The .p12's password. |
| `SPARKLE_PRIVATE_KEY` | The update key, from Sparkle's `generate_keys --account mailer -x <file>`. Its public half is `SUPublicEDKey` in `Resources/Info.plist`. Keep a backup: without it no update can be signed for the copies already installed. |

Without them, `main` is still built and tested but not released. Published builds carry no
Google client ID; Mailer keeps yours on your Mac.

### Google setup (once, free, about 10 minutes)

Mailer signs in through **your own** Google Cloud project, so nobody else ever holds access
to your mail. The client ID you copy at the end isn't a password (Google shows it in every
sign-in link), but it stays out of the repository in `GoogleClientID.txt`.

1. Open [console.cloud.google.com](https://console.cloud.google.com). Click the project picker
   at the top, then **New project**. Name it `Mailer`, click **Create**, then select it.
2. **APIs & Services → Library.** Search **Gmail API**, open it and click **Enable**. Go back,
   search **People API** and click **Enable**.
3. **Google Auth Platform → Branding** (older consoles call it "OAuth consent screen"):
   - App name `Mailer`; support email and developer contact: your Gmail.
   - A home page and a privacy policy link are needed before the app can be published. The
     repository's page and its Privacy section will do; add their domain under
     **Authorized domains**. Leave the logo empty, since uploading one requires Google's review.
   - **Audience → External.** Then click **Publish app** so the status reads **In
     production**. In "Testing", only listed test users can sign in, and Google signs them out
     every 7 days.
   - **Data access → Add or remove scopes.** Paste these, click **Update**, then **Save**:
     - `https://mail.google.com/`
     - `https://www.googleapis.com/auth/contacts.readonly`
     - `https://www.googleapis.com/auth/contacts.other.readonly`
     - `.../auth/userinfo.email` and `.../auth/userinfo.profile`
   - You don't need Google's verification for your own use (up to 100 users). At sign-in
     Google shows "Google hasn't verified this app": click **Advanced → Go to Mailer**.
     The warning is about your own project.
4. **Google Auth Platform → Clients → Create client.**
   - Application type: **iOS** (the right type for a Mac app using this sign-in).
   - Bundle ID: `com.oiharshit.postline`, the app ID Mailer kept from Postline (or your own,
     if you change `BUNDLE_ID` in `build.sh` and `Resources/Info.plist`).
   - Click **Create** and copy the **Client ID** (it ends in `.apps.googleusercontent.com`).
5. Save it in `GoogleClientID.txt` next to `build.sh` (or set `MAILER_GOOGLE_CLIENT_ID`),
   run `./build.sh install`, and click **Continue with Google** once for each account.

### Writing model (optional)

Writing help runs on Qwen 3.5 4B (MLX, 4-bit, about 3 GB) if it's in your Hugging Face cache,
and on Apple's on-device model otherwise (with Apple Intelligence turned on). To use Qwen:

```bash
pip install -U huggingface_hub
hf download mlx-community/Qwen3.5-4B-MLX-4bit
```

It loads the first time you need it and is let go after 3 idle minutes. Settings → Writing help
says which model is in use, and has a switch for each kind of help.

### Error and crash reporting (optional)

Mailer can send errors, crashes, hangs, timings and log lines to a GlitchTip (or Sentry)
project of your own, through the Sentry SDK. Put the project's DSN in `GlitchTipDSN.txt` next
to `build.sh` (or set `MAILER_GLITCHTIP_DSN`); it stays out of the repository. The app keeps
it on your Mac, so the published updates, which carry none, go on reporting. Reporting is still
off until you turn on Settings → Diagnostics. A Mac that has never run a build with a DSN has no
switch and sends nothing.

So that crashes show function names, `build.sh` writes `build/Mailer.app.dSYM` and uploads it
with `sentry-cli` when `GLITCHTIP_AUTH_TOKEN` is set (a GlitchTip auth token with
`project:write`). `GLITCHTIP_ORG` and `GLITCHTIP_PROJECT` name the project (default
`personal`/`mailer`). For the published updates, CI does the same when the repository has the
`GLITCHTIP_AUTH_TOKEN` and `GLITCHTIP_URL` secrets.

## Change it

Everything is plain Swift, laid out by job. Comments say *why* things are the way they are,
including what was measured and what was tried first.

| Piece | File |
|---|---|
| Window, menus, menu bar icon, keyboard shortcuts | `Sources/Mailer/App/MailerApp.swift` |
| App state and every action (archive, undo, swipe, batch) | `Sources/Mailer/App/AppModel.swift` |
| Sample mail for `./build.sh demo` | `Sources/Mailer/App/DemoData.swift` |
| Colours, type, spacing, corner radii, motion | `Sources/Mailer/Design/` |
| Screens: inbox, reader, compose, settings, onboarding | `Sources/Mailer/Features/` |
| Showing an email: privacy rules, loading, tracking pixels | `Features/Reader/HTMLView.swift`, `Features/Reader/TrackingImageFilter.swift` |
| Export for AI | `Core/ThreadExport.swift`, `Core/MailMarkdown.swift`, `Core/QuotedHistory.swift`, `Features/Reader/ExportSheet.swift` |
| Google sign-in (PKCE, one refresh token per account in the Keychain) | `Core/GoogleAuth.swift`, `Core/Config.swift` |
| Gmail REST calls, Gmail JSON → message, Gmail labels ↔ neutral state | `Core/GmailAPI.swift`, `Core/MessageParser.swift`, `Core/GmailMapping.swift` |
| SQLite + FTS5 database, its schema and migrations | `Core/Store.swift`, `Core/Models.swift` |
| Sync, import, the 2-minute Inbox check | `Core/SyncEngine.swift` |
| Live IMAP IDLE (XOAUTH2) | `Core/LiveWatcher.swift`, `Core/IMAPClient.swift` |
| Code detection | `Core/CodeFinder.swift` + `Sources/OTPCore` |
| Notifications with Copy code | `Core/Notifier.swift` |
| Suggested replies, ghost text, grammar | `Core/Writer.swift`, `Features/Compose/SmartEditor.swift` |
| Timings | `Core/Performance.swift`, `tools/performance_report.py` |
| Log lines, error and crash reporting | `Core/Log.swift`, `Core/Telemetry.swift` |
| Icons (Hugeicons, exported by `tools/export-icons.mjs`) | `Resources/Icons` |

Logs go to `~/Library/Logs/Postline.log`. (Mailer's data keeps Postline's folder names; see
the Roadmap.)

### Measuring performance

The operations that have to stay fast are timed every time they run: opening an email
(`reader.*`), listing a mailbox (`list.reload`) and syncing (`sync.*`). The timings are kept
on your Mac, in `~/Library/Logs/Postline-performance.jsonl`, and with diagnostics on they also
go to GlitchTip as transactions, the reader's steps as spans inside `reader.open` and
`reader.page_load` (sync is sampled at 1 in 20). To summarise the local file:

```bash
tools/performance_report.py --since 30          # last 30 minutes: median, p90, p99, worst
tools/performance_report.py --op reader --by remote --slowest 10
```

| Timing | From → to |
|---|---|
| `reader.open` | clicking an email → the text of every message in its thread shown |
| `reader.thread_query` | reading the thread from the database |
| `reader.prepare_html` | removing tracking pixels and wrapping the email's HTML |
| `reader.webview_create` | creating the web view for one message |
| `reader.dom_ready` | starting the page → its text laid out and shown |
| `reader.page_load` | starting the page → everything loaded, images included |
| `list.reload` | redrawing the message list |
| `sync.history`, `sync.reconcile` | one check with Gmail |

To see *why* something is slow, record it in Instruments. The same timings appear as
labelled intervals in the Points of Interest lane, above the CPU samples:

```bash
mkdir -p build/traces
xcrun xctrace record --template 'Time Profiler' --attach Mailer --time-limit 30s \
    --output build/traces/reader.trace     # use Mailer during the 30 s
open build/traces/reader.trace
```

Each email is drawn in WebKit's own processes (`com.apple.WebKit.WebContent`), so for
rendering work record with `--all-processes` instead of `--attach Mailer`.

## Keyboard

**J/K** or the arrow keys move between conversations; **E** archives; **#** trashes; **R**,
**A** and **F** reply, reply all and forward; **C** composes; **S** pins; **U** marks read or
unread; **/** or ⌘F searches; ⇧⌘E exports the thread for AI; ⌘↩ sends; ⌘Z undoes.
Single-key shortcuts are off while you write.

## Privacy

Mailer has no server and no analytics. Your mail, contacts and sign-in tokens stay on your Mac
(database in `~/Library/Application Support/Postline`, tokens in the Keychain), and the app
talks only to Google's own Gmail, People and sign-in endpoints. Writing help runs on your Mac.

Error and crash reporting is off by default and exists only in a build given a GlitchTip DSN
(see [Error and crash reporting](#error-and-crash-reporting-optional)). Turned on in Settings →
Diagnostics, it sends errors, crashes, hangs, timings and log lines to that GlitchTip. Error
messages and log lines can name your accounts and attachments; the text of your emails, network
requests and the SDK's default user data are not sent.

Email loads in full, but its tracking pixels (tiny or hidden images, and the open-tracking
addresses of the common mailing tools) are removed first, so most senders can't tell when you
opened their mail. To block every remote image instead, turn off Settings → Privacy → Load
remote images. Scripts never run, and an email can't redirect the reader to a web page.
Company logos are off by default: they're looked up through Google's favicon service, which
would see the domain of each company that writes to you.

When cloud AI arrives (see the Roadmap), it will be off until you turn it on, feature by
feature, and Export for AI only ever writes a file or the clipboard; you choose where it goes.

## Credits

- Forked from [Postline](https://github.com/oiharshit/postline), made by
  [Harshit Maurya](https://oiharshit.com).
- Icons: [Hugeicons](https://hugeicons.com) free set, MIT (`Resources/Icons/LICENSE-Hugeicons.md`).
- Code detector and the IMAP client it builds on: [OpenOTP](https://github.com/jeninh/openotp), MIT
  (`Sources/OTPCore/LICENSE-OpenOTP.txt`).
- Writing model: [Qwen](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit) via
  [MLX Swift](https://github.com/ml-explore/mlx-swift).
- Inspired by the flows of Spark and Notion Mail; no code or artwork from either is used.

## Licence

MIT — see [LICENSE](LICENSE).
