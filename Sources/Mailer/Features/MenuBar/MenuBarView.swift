import SwiftUI

/// The menu behind the menu bar icon, which is there only for five minutes
/// after new Primary mail or a sign-in code arrives: the waiting code one
/// click from the clipboard, and the new emails one click from opening.
struct MenuBarView: View {
    let model: AppModel

    var body: some View {
        if model.menuIcon.showsCode {
            ForEach(model.codes.prefix(3)) { code in
                Button("Copy \(code.code)  ·  \(code.sender)") { Notifier.shared.copy(code.code) }
            }
            if let latest = model.codes.first, !latest.account.isEmpty {
                Button("Open the code's email") { model.open(account: latest.account, messageID: latest.messageID) }
            }
            Divider()
        }
        if !model.recentMail.isEmpty {
            Section("New mail") {
                ForEach(model.recentMail) { m in
                    Button("\(m.senderLabel)  ·  \(m.subject.isEmpty ? "(no subject)" : m.subject)") {
                        model.open(account: m.account, messageID: m.id)
                    }
                }
            }
            Divider()
        }
        Button("Open Mailer") { model.showMainWindow() }
        Button("Hide this icon") { model.hideMenuIcon() }
    }
}
