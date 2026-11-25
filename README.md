# Postline

A fast, private Gmail app for the Mac. Native SwiftUI, with no server in between:
each account talks straight to Gmail, and your mail is kept in a small database on
your Mac, so opening, switching and searching never wait on the network.

![Postline's inbox](https://github.com/oiharshit/postline/releases/latest/download/inbox.png)

- **Fast.** A mailbox opens in 1–2 ms and a search takes 4–5 ms (measured on 2,000 stored
  messages). New mail shows up within about 5 s of landing in Gmail: a history check runs
  every 5 s next to an IMAP IDLE connection, because Gmail's IDLE pings were measured
  arriving 7–47 s late.
- **Inbox is Gmail's Primary tab**, decided by Gmail itself (`in:inbox category:primary`).
  Everything else Gmail files in its Inbox sits under **Other**.
- **Sign-in codes.** A code gets its own notification with the code as the title and a
  **Copy code** button. Click any notification to open that email.
- **Out of the way.** No Dock icon and normally no menu bar icon. A menu bar icon appears
  for 5 minutes when new Primary mail arrives (an envelope) or a code arrives (a key, gone
  once you copy it). Closing or minimizing the window keeps Postline running; open it again
  from Applications or Spotlight.
- **Writing help, on your Mac only.** Three faint suggested replies under each email from a
  person, ghost text while you write (**Tab** or **→** takes it), and grammar fixes on
  sentences you've finished (⌘Z undoes). Suggestions never add a number (time, date,
  amount) that isn't already in the email or your draft.
- **Swipe and batch.** Two-finger swipe right to archive, left to Trash. **⌘-click**,
  **⇧-click** or **⌘A** to pick several, then archive, delete or mark them read together.
  Everything can be undone with ⌘Z.
- **Starts empty.** Only mail that arrives after you connect is downloaded. Import older mail
  (7 days, 30 days, 3 months, 1 year or everything) at sign-in or later in Settings.
- **Several Gmail accounts**, one Inbox or one at a time. Real photos from Google Contacts,
  company logos, and initials as a fallback.
- **Send as any address** Gmail lets you send as, with 5 seconds to Undo.

![Reading an email, with suggested replies](https://github.com/oiharshit/postline/releases/latest/download/reader.png)

Needs macOS 15 or later on an Apple silicon Mac.

## Install

**Download:** get `Postline.dmg` from the
[latest release](https://github.com/oiharshit/postline/releases/latest),
open it and drag Postline to Applications. It's notarized by Apple.

The download signs in through the Postline Google project, which Google hasn't verified.
That means Google shows "Google hasn't verified this app" at sign-in (click **Advanced →
Go to Postline**), and the project has room for 100 people in total. To skip both, build
it yourself with your own free Google project (below). Your mail still never passes through
anyone's server either way: Postline talks only to Google.

## Build it yourself

You need Xcode 16.3 or later (or its command-line tools) and the Metal Toolchain for the
writing model:

```bash
xcodebuild -downloadComponent MetalToolchain   # once (or Xcode → Settings → Components)

git clone https://github.com/oiharshit/postline.git
cd postline
./build.sh demo       # try it with sample mail, no account needed
```

To use your own mail, do the Google setup below once, then:

```bash
echo "YOUR-CLIENT-ID.apps.googleusercontent.com" > GoogleClientID.txt
./build.sh install    # builds, copies to /Applications and opens it
```

| Command | What it does |
|---|---|
| `./build.sh` | builds `build/Postline.app` |
| `./build.sh run` | builds and launches it |
| `./build.sh demo` | launches with sample mail in a separate database |
| `./build.sh install` | copies it to /Applications and opens it |
| `./build.sh release` | makes a notarized `build/Postline.dmg` (Developer ID needed) |
| `swift test` | runs the tests (code detection, Gmail parsing, database, outgoing mail, writing help, menu bar timing) |

The app is signed with your Apple Development certificate if you have one (add a free Apple
ID in Xcode → Settings → Accounts), otherwise ad hoc. Ad hoc works too; macOS may just ask
again for Keychain access after each rebuild.

### Google setup (once, free, about 10 minutes)

Postline signs in through **your own** Google Cloud project, so nobody else ever holds access
to your mail. The client ID you copy at the end isn't a password (Google shows it in every
sign-in link), but it stays out of the repository in `GoogleClientID.txt`.

1. Open [console.cloud.google.com](https://console.cloud.google.com). Click the project picker
   at the top, then **New project**. Name it `Postline`, click **Create**, then select it.
2. **APIs & Services → Library.** Search **Gmail API**, open it and click **Enable**. Go back,
   search **People API** and click **Enable**.
3. **Google Auth Platform → Branding** (older consoles call it "OAuth consent screen"):
   - App name `Postline`; support email and developer contact: your Gmail.
   - **Audience → External.** Then click **Publish app** so the status reads **In
     production**. In "Testing", Google signs you out every 7 days.
   - **Data access → Add or remove scopes.** Paste these, click **Update**, then **Save**:
     - `https://mail.google.com/`
     - `https://www.googleapis.com/auth/contacts.readonly`
     - `https://www.googleapis.com/auth/contacts.other.readonly`
     - `.../auth/userinfo.email` and `.../auth/userinfo.profile`
   - You don't need Google's verification for your own use (up to 100 users). At sign-in
     Google shows "Google hasn't verified this app": click **Advanced → Go to Postline**.
     The warning is about your own project.
4. **Google Auth Platform → Clients → Create client.**
   - Application type: **iOS** (the right type for a Mac app using this sign-in).
   - Bundle ID: `com.oiharshit.postline` (or your own, if you change `BUNDLE_ID` in
     `build.sh` and `Resources/Info.plist`).
   - Click **Create** and copy the **Client ID** (it ends in `.apps.googleusercontent.com`).
5. Save it in `GoogleClientID.txt` next to `build.sh` (or set `POSTLINE_GOOGLE_CLIENT_ID`),
   run `./build.sh install`, and click **Continue with Google** once for each account.

### Writing model (optional)

Writing help runs on Qwen 3.5 4B (MLX, 4-bit, about 3 GB) if it's in your Hugging Face cache,
and on Apple's on-device model otherwise (Apple Intelligence Macs). To use Qwen:

```bash
pip install -U huggingface_hub
hf download mlx-community/Qwen3.5-4B-MLX-4bit
```

It loads the first time you need it and is let go after 3 idle minutes. Settings has a switch
for each kind of help.

## Change it

Everything is plain Swift, laid out by job. Comments say *why* things are the way they are,
including what was measured and what was tried first.

| Piece | File |
|---|---|
| Window, menus, menu bar icon, keyboard shortcuts | `Sources/Postline/App/PostlineApp.swift` |
| App state and every action (archive, undo, swipe, batch) | `Sources/Postline/App/AppModel.swift` |
| Sample mail for `./build.sh demo` | `Sources/Postline/App/DemoData.swift` |
| Colours, type, spacing, corner radii, motion | `Sources/Postline/Design/` |
| Screens: inbox, reader, compose, settings, onboarding | `Sources/Postline/Features/` |
| Google sign-in (PKCE, one refresh token per account in the Keychain) | `Core/GoogleAuth.swift`, `Core/Config.swift` |
| Gmail REST calls, and Gmail JSON → message | `Core/GmailAPI.swift`, `Core/MessageParser.swift` |
| SQLite + FTS5 database | `Core/Store.swift` |
| Sync, import, the 2-minute Inbox check | `Core/SyncEngine.swift` |
| Live IMAP IDLE (XOAUTH2) | `Core/LiveWatcher.swift`, `Core/IMAPClient.swift` |
| Code detection | `Core/CodeFinder.swift` + `Sources/OTPCore` |
| Notifications with Copy code | `Core/Notifier.swift` |
| Menu bar icon timing | `Core/MenuIconClock.swift` |
| Suggested replies, ghost text, grammar | `Core/Writer.swift`, `Features/Compose/SmartEditor.swift` |
| Icons (Hugeicons, exported by `tools/export-icons.mjs`) | `Resources/Icons` |

Logs go to `~/Library/Logs/Postline.log`.

## Keyboard

**J/K** or the arrow keys move between conversations; **E** archives; **#** trashes; **R**,
**A** and **F** reply, reply all and forward; **C** composes; **S** pins; **U** marks read or
unread; **/** or ⌘F searches; ⌘↩ sends; ⌘Z undoes. Single-key shortcuts are off while you write.

## Privacy

Postline has no server. Your mail, contacts and sign-in tokens stay on your Mac (database in
`~/Library/Application Support/Postline`, tokens in the Keychain), and the app talks only to
Google's own Gmail, People and sign-in endpoints. Writing help runs on your Mac.

## Credits

- Made by [Harshit Maurya](https://oiharshit.com).
- Icons: [Hugeicons](https://hugeicons.com) free set, MIT (`Resources/Icons/LICENSE-Hugeicons.md`).
- Code detector and the IMAP client it builds on: [OpenOTP](https://github.com/jeninh/openotp), MIT
  (`Sources/OTPCore/LICENSE-OpenOTP.txt`).
- Writing model: [Qwen](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit) via
  [MLX Swift](https://github.com/ml-explore/mlx-swift).
- Inspired by the flows of Spark and Notion Mail; no code or artwork from either is used.

## Licence

MIT — see [LICENSE](LICENSE).
