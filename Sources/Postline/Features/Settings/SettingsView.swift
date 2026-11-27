import SwiftUI

/// Accounts (add, import older mail, remove), notifications and codes, and
/// opening at login. Nothing else.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var prefs = Preferences.shared
    @State private var importFor: Account?
    @State private var removing: Account?
    @State private var notificationsAllowed: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Accounts") {
                    VStack(spacing: 0) {
                        ForEach(model.accounts) { a in
                            accountRow(a)
                            if a.id != model.accounts.last?.id { Hairline().padding(.leading, 56) }
                        }
                    }
                    .card(radius: Theme.Radius.card)
                    Button {
                        Task { if let a = await model.connectAccount() { importFor = a } }
                    } label: {
                        HStack(spacing: 8) { IconView(.plus, size: 15); Text(model.addingAccount ? "Waiting for Google…" : "Add Gmail account") }
                    }
                    .buttonStyle(QuietButtonStyle(height: 34, fullWidth: false))
                    .disabled(model.addingAccount || !Config.isConfigured)
                }

                section("Notifications") {
                    Picker("Notify me about", selection: $prefs.notify) {
                        ForEach(Preferences.Notify.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Codes always notify, with a Copy code button. Clicking a notification opens the email.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    Toggle("Copy codes to the clipboard automatically", isOn: $prefs.autoCopyCodes)
                        .font(.callout)
                    HStack(spacing: 10) {
                        Circle().fill(notificationsAllowed == true ? Theme.green : Theme.red).frame(width: 7, height: 7)
                        Text(notificationsAllowed == true ? "Notifications are allowed" :
                             notificationsAllowed == false ? "Notifications are off for Postline" : "Checking notifications…")
                            .font(.callout).foregroundStyle(Theme.body)
                        Spacer()
                        if notificationsAllowed == false {
                            Button("Turn on") {
                                Task {
                                    if await Notifier.shared.requestPermission() { notificationsAllowed = true }
                                    else if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                            .buttonStyle(QuietButtonStyle(height: 30, fullWidth: false))
                        }
                        Button("Send test notification") { Notifier.shared.sendTest() }
                            .buttonStyle(QuietButtonStyle(height: 30, fullWidth: false))
                    }
                    .task {
                        let status = await Notifier.shared.authorizationStatus()
                        notificationsAllowed = status == .authorized || status == .provisional
                    }
                }

                section("Writing help") {
                    Toggle("Suggest quick replies under each email", isOn: $prefs.suggestReplies).font(.callout)
                    Toggle("Finish my sentences as I type (Tab to accept)", isOn: $prefs.ghostText).font(.callout)
                    Toggle("Fix grammar in sentences I've finished", isOn: $prefs.fixGrammar).font(.callout)
                    Text("Runs on \(Writer.backend().title). Nothing you write leaves this Mac.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }

                section("Privacy") {
                    Toggle("Load remote images", isOn: $prefs.loadRemoteImages).font(.callout)
                    Text("Tracking pixels are removed before an email loads, so most senders can't tell when you opened it. Turn this off to block every remote image.")
                        .font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Show company logos", isOn: $prefs.companyLogos).font(.callout)
                    Text("Logos are looked up through Google's favicon service, which sees the domain of each company that writes to you.")
                        .font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onChange(of: prefs.companyLogos) { _, on in
                    if on { Avatars.shared.forgetMisses() }
                }

                section("General") {
                    Picker("Appearance", selection: $prefs.appearance) {
                        ForEach(Preferences.Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    Toggle("Open Postline at login, so mail and codes always arrive", isOn: $prefs.openAtLogin)
                        .font(.callout)
                }
            }
            .padding(28)
        }
        .frame(width: 560, height: 620)
        .task { model.refreshSignedOut() }
        .background(Theme.panel)
        .sheet(item: $importFor) { account in ImportSheet(model: model, account: account) }
        .confirmationDialog("Remove \(removing?.email ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove account", role: .destructive) {
                if let removing { Task { await model.remove(removing) } }
            }
        } message: {
            Text("Its mail is deleted from this Mac and Postline is signed out of it. Nothing changes in Gmail.")
        }
    }

    private func accountRow(_ a: Account) -> some View {
        HStack(spacing: 12) {
            AvatarView(email: a.email, name: a.displayName, account: a.email, picture: a.pictureURL, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.displayName).font(.calloutStrong).foregroundStyle(Theme.ink)
                Text(sendAsLine(a)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                if let p = model.importProgress[a.email] {
                    Text(p.total == 0 ? "Finding older mail…" : "Importing \(p.done) of \(p.total)").font(.caption).foregroundStyle(Theme.accent)
                }
                if model.signedOut.contains(a.email) {
                    Text("Signed out. Mail isn't syncing.").font(.caption).foregroundStyle(Theme.red)
                }
            }
            Spacer()
            if model.signedOut.contains(a.email) {
                Button(model.addingAccount ? "Waiting for Google…" : "Sign in again") { Task { await model.signInAgain(a) } }
                    .buttonStyle(.plain).font(.calloutStrong).foregroundStyle(Theme.accent)
                    .disabled(model.addingAccount || !Config.isConfigured)
            } else {
                Button("Import older mail") { importFor = a }
                    .buttonStyle(.plain).font(.calloutStrong).foregroundStyle(Theme.accent)
                    .disabled(model.importProgress[a.email] != nil)
            }
            IconButton(icon: .logout, help: "Remove account") { removing = a }
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
    }

    private func sendAsLine(_ a: Account) -> String {
        let extra = a.sendAs.map(\.email).filter { $0 != a.email }
        return extra.isEmpty ? a.email : "\(a.email) · sends as \(extra.joined(separator: ", "))"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.ui(13, .semibold)).foregroundStyle(Theme.muted)
            content()
        }
    }
}

/// "Import older emails?" for an account that is already connected.
struct ImportSheet: View {
    let model: AppModel
    let account: Account
    @State private var range: AppModel.ImportRange = .month
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import older emails").font(.ui(17, .semibold)).foregroundStyle(Theme.ink)
            Text("For \(account.email). It runs in the background; new mail keeps arriving meanwhile, and mail already on this Mac is skipped.")
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(AppModel.ImportRange.allCases.filter { $0 != .none }) { option in
                    ImportOption(title: option.title, detail: "", selected: range == option) { range = option }
                }
            }
            HStack {
                Button("Not now") { dismiss() }.buttonStyle(QuietButtonStyle(height: 34))
                Button("Import") { model.startImport(account.email, range: range); dismiss() }
                    .buttonStyle(AccentButtonStyle(height: 34))
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
