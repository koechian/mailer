import SwiftUI

/// First run, laid out like Notion Mail's sign-up: one centred column on the
/// canvas, a title, a quiet second line, and one decision per screen.
///
///   Welcome → Sign in with Google → Import older mail? → Notifications → Done
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step: Step = .welcome
    @State private var connected: Account?
    @State private var range: AppModel.ImportRange = .week
    @State private var clientIDDraft = ""
    /// A client ID was pasted and saved; Config is not observed, so this redraws.
    @State private var clientIDSaved = false

    enum Step { case welcome, importMail, notifications, done }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case .welcome: welcome
                    case .importMail: importMail
                    case .notifications: notifications
                    case .done: done
                    }
                }
                .frame(width: 400)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .animation(Theme.Motion.spring, value: step)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            mark
            heading("Welcome to Mailer", "Fast mail for your Gmail accounts. Your mail is kept on this Mac, and nothing passes through anyone's server.")
            if Config.isConfigured || clientIDSaved {
                Button {
                    Task {
                        if let account = await model.connectAccount() {
                            connected = account
                            step = .importMail
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if model.addingAccount { ProgressView().controlSize(.small) } else { IconView(.user, size: 16) }
                        Text(model.addingAccount ? "Waiting for Google…" : "Continue with Google")
                    }
                }
                .buttonStyle(QuietButtonStyle(height: 40))
                .disabled(model.addingAccount)
                Text("Mailer asks Google for permission to read, organise and send your mail, and to see your contacts' photos.")
                    .font(.caption).foregroundStyle(Theme.muted2).multilineTextAlignment(.center)
            } else {
                setupNeeded
            }
        }
    }

    /// Shown until Mailer has a Google OAuth client ID: this build carries
    /// none and none is kept on this Mac (a downloaded build, first run).
    private var setupNeeded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconView(.key, size: 16).foregroundStyle(Theme.Hue.amber.ink)
                Text("One setup step first").font(.calloutStrong).foregroundStyle(Theme.ink)
            }
            Text("Mailer signs in through your own free Google Cloud project, so no company sits between you and Gmail. The README has the click-by-click steps. Paste the client ID it gives you here.")
                .font(.callout).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("…apps.googleusercontent.com", text: $clientIDDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveClientID)
                Button("Save", action: saveClientID)
                    .buttonStyle(QuietButtonStyle(height: 28, fullWidth: false))
                    .disabled(!Config.isValidClientID(clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Hue.amber.tint))
    }

    private func saveClientID() {
        clientIDSaved = Config.saveClientID(clientIDDraft)
    }

    private var importMail: some View {
        VStack(spacing: 22) {
            if let connected {
                AvatarView(email: connected.email, name: connected.displayName, account: connected.email, picture: connected.pictureURL, size: 56)
            }
            heading("Import older emails?", "Mailer starts with an empty inbox and shows mail from now on. You can bring in older mail now, or later from Settings.")
            VStack(spacing: 6) {
                ForEach(AppModel.ImportRange.allCases) { option in
                    ImportOption(title: option.title, detail: detail(option), selected: range == option) { range = option }
                }
            }
            Button(range == .none ? "Continue" : "Import and continue") {
                if let connected { model.startImport(connected.email, range: range) }
                step = .notifications
            }
            .buttonStyle(AccentButtonStyle())
        }
    }

    private func detail(_ r: AppModel.ImportRange) -> String {
        switch r {
        case .none: "Start fresh — fastest"
        case .week, .month: "A few seconds"
        case .quarter, .year: "A minute or two, in the background"
        case .all: "Everything Gmail has; can take a while"
        }
    }

    private var notifications: some View {
        VStack(spacing: 22) {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.Hue.green.tint)
                .frame(width: 64, height: 64)
                .overlay(IconView(.notification, size: 30).foregroundStyle(Theme.Hue.green.ink))
            heading("Know the moment mail lands", "New mail shows a notification. Sign-in codes show the code itself with a Copy button, and clicking any notification opens the email.")
            Button("Turn on notifications") {
                Task {
                    _ = await Notifier.shared.requestPermission()
                    step = .done
                }
            }
            .buttonStyle(AccentButtonStyle())
            Button("Not now") { step = .done }
                .buttonStyle(.plain).font(.callout).foregroundStyle(Theme.muted)
        }
    }

    private var done: some View {
        VStack(spacing: 22) {
            heading("You're all set", "Connected accounts:")
            VStack(spacing: 6) {
                ForEach(model.accounts) { a in
                    HStack(spacing: 10) {
                        AvatarView(email: a.email, name: a.displayName, account: a.email, picture: a.pictureURL, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.displayName).font(.calloutStrong).foregroundStyle(Theme.ink)
                            Text(a.email).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        IconView(.tick, size: 16).foregroundStyle(Theme.green)
                    }
                    .padding(.horizontal, 12).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.line))
                }
            }
            Button {
                Task {
                    if let account = await model.connectAccount() {
                        connected = account
                        range = .week
                        step = .importMail
                    }
                }
            } label: {
                HStack(spacing: 8) { IconView(.plus, size: 15); Text("Add another account") }
            }
            .buttonStyle(QuietButtonStyle(height: 38))
            Button("Open inbox") { Preferences.shared.onboarded = true }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.return, modifiers: [])
        }
    }

    // MARK: Parts

    private var mark: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Theme.primary)
            .frame(width: 64, height: 64)
            .overlay(IconView(.mail, size: 32).foregroundStyle(Theme.onPrimary))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.ui(24, .semibold)).foregroundStyle(Theme.ink)
            Text(detail).font(.ui(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ImportOption: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? Theme.accent : Theme.muted2, lineWidth: selected ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                Text(title).font(.calloutStrong).foregroundStyle(Theme.ink)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(selected ? Theme.accentTint : hovering ? Theme.fillHover : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
