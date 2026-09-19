//
//  CommunityReport.swift
//  Learn2Sing
//
//  Reporting what somebody else published: a flag in the toolbar of a community
//  exercise's intro screen and of an uploader's profile, opening a sheet the user
//  writes their reason in. It goes to the developer through the same endpoint as
//  Settings ▸ "Request a New Feature / Report a Bug" (see `FeedbackSender`), as a
//  message of the type "Report", with no address to answer.
//
//  The same sheet is where a user is blocked: a switch under the reason, which
//  hides everything that user publishes from this one (see BlockedUsers). A
//  block is always reported too, with or without a reason, so the developer
//  hears about whoever it was aimed at.
//

import SwiftUI

/// What a report is about: a public exercise, or the public profile of whoever
/// uploaded some. Carries the ids the developer needs to find it again, since the
/// message itself is only what the user wrote.
enum CommunityReport {
    /// A community exercise, by the public id it is listed under, and whoever
    /// uploaded it. `uploaderID` is nil when no list fetched this session named
    /// them; the report still goes, the exercise id being enough to find it.
    case exercise(id: UUID, name: String, uploaderID: String?, uploaderName: String)
    /// An uploader's profile, by the public user id it is fetched under.
    case profile(id: String, name: String)

    /// Sent as the message's `subject`, where the Settings form sends its "Where
    /// in the app" pick. English whatever language the app is in, like the raw
    /// values of `FeedbackLocation`: it is read at the other end, not here.
    fileprivate var subject: String {
        switch self {
        case .exercise: "Public Exercise"
        case .profile: "Public Profile"
        }
    }

    /// Written under the user's own words, so the developer can tell which
    /// exercise or profile the report is about. English, like `subject`.
    fileprivate var reference: String {
        switch self {
        case .exercise(let id, let name, let uploaderID, let uploaderName):
            """
            Reported exercise: \(name)
            Exercise id: \(id.uuidString.lowercased())
            Uploaded by: \(uploaderName.isEmpty ? "unknown" : uploaderName)
            Uploader id: \(uploaderID ?? "unknown")
            """
        case .profile(let id, let name):
            """
            Reported profile: \(name)
            User id: \(id)
            """
        }
    }

    /// Whether this is the user's own exercise or profile, which there is nobody
    /// to report to about: the screen leaves the flag out.
    var isOwn: Bool {
        switch self {
        case .exercise(_, _, let uploaderID, _): uploaderID == PublicIdentifier.user
        case .profile(let id, _): id == PublicIdentifier.user
        }
    }

    /// Who the sheet's block switch blocks: whoever uploaded the exercise, or
    /// the owner of the profile. nil for an exercise whose uploader no list has
    /// named this session, which leaves the switch out: there is no id to block.
    var blockTarget: BlockedUser? {
        switch self {
        case .exercise(_, _, let uploaderID, let uploaderName):
            uploaderID.map { BlockedUser(id: $0, name: uploaderName) }
        case .profile(let id, let name):
            BlockedUser(id: id, name: name)
        }
    }

    /// The flag's explanation, held for on the screen that shows it.
    var buttonHelp: String {
        switch self {
        case .exercise:
            L("Tells the developer about this exercise if it's offensive, spam or doesn't belong here. You can also block whoever made it, which hides everything they publish from you.")
        case .profile:
            L("Tells the developer about this profile if its name, picture or description is offensive or doesn't belong here. You can also block this user, which hides everything they publish from you.")
        }
    }

    fileprivate var sheetTitle: String {
        switch self {
        case .exercise: L("Report Exercise")
        case .profile: L("Report Profile")
        }
    }

    fileprivate var prompt: String {
        switch self {
        case .exercise: L("Why are you reporting this exercise?")
        case .profile: L("Why are you reporting this profile?")
        }
    }

    /// Posts the report and says whether the server took it. A block goes with
    /// a line saying so, and may come with no reason at all.
    fileprivate func send(_ message: String, blocking: Bool) async -> Bool {
        let reason = message.isEmpty ? "(No reason given.)" : message
        let block = blocking ? "\nThe reporter blocked this user." : ""
        return await FeedbackSender.send(severity: "Report",
                                         subject: subject,
                                         message: "\(reason)\n\n---\n\(reference)\(block)",
                                         email: "")
    }
}

extension View {
    /// The sheet the report flag opens, and the flag's press-and-hold help. Goes
    /// on the screen whose toolbar holds the flag: a `Label` toolbar button is
    /// made into a native bar button, which drops any modifier put on it (see
    /// `explainBarButton`), so neither could hang off the button itself.
    ///
    /// nil for a screen that shows no flag: the exercise intro screen outside
    /// the community, which takes this unconditionally.
    func communityReportSheet(_ report: CommunityReport?, isPresented: Binding<Bool>) -> some View {
        modifier(CommunityReportSheet(report: report, isPresented: isPresented))
    }
}

/// What `communityReportSheet` puts on a screen.
///
/// A block the sheet sent is held here until the sheet has gone, and only made
/// then. Blocking takes the blocked user's screens off the navigation stack (see
/// CommunityView and HomeView), this one included, and popping the screen a
/// sheet is presented from while that sheet is still closing is asking for the
/// two animations to trip over each other.
private struct CommunityReportSheet: ViewModifier {
    let report: CommunityReport?
    @Binding var isPresented: Bool

    @State private var pendingBlock: BlockedUser?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: blockIfSent) {
                if let report {
                    CommunityReportView(report: report) { pendingBlock = $0 }
                }
            }
            // With no flag on screen there is no button for the hold to find, so
            // the empty explanation is never asked for.
            .explainBarButton(L("Report"), report?.buttonHelp ?? "")
    }

    private func blockIfSent() {
        guard let user = pendingBlock else { return }
        pendingBlock = nil
        BlockedUsers.shared.block(user)
    }
}

/// The sheet a report is written in: one field for the reason, a switch that
/// blocks the user as well, Cancel and Send. Nothing is kept: a sent report
/// closes the sheet behind a toast, and one the server didn't take stays on
/// screen to be sent again, like the Settings form. A block waits on the report
/// in the same way, so a user is never blocked without the developer hearing of
/// it.
private struct CommunityReportView: View {
    /// Re-renders when the language is changed in Settings; the strings are
    /// resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss

    let report: CommunityReport
    /// Handed the user to block once the report has gone, for the screen to
    /// block when the sheet has closed (see `CommunityReportSheet`).
    let onBlock: (BlockedUser) -> Void

    @State private var message = ""
    /// The block switch. Off to begin with: a report is about one exercise or
    /// profile, and hiding everything its author ever publishes is a bigger
    /// step the user takes on purpose.
    @State private var blocksUser = false
    @State private var isSending = false
    /// Set when the server didn't take the report, and shown in an alert. The
    /// reason stays in the field, so Send can just be tapped again.
    @State private var failure: String?

    @FocusState private var isWriting: Bool

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A reason, or a block, or both: a block is reason enough to write to the
    /// developer on its own.
    private var canSend: Bool {
        !isSending && (!trimmedMessage.isEmpty || blocksUser && report.blockTarget != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(report.prompt, text: $message, axis: .vertical)
                    .lineLimit(5...15)
                    .focused($isWriting)
                    .settingHelp(L("Why you're reporting it. The more exactly you say what's wrong, the easier it is to do something about it."))

                // A section of its own, so it reads as a second thing the sheet
                // does rather than as part of the reason.
                if let target = report.blockTarget {
                    Section {
                        Toggle(isOn: $blocksUser) {
                            Text(verbatim: target.name.isEmpty
                                 ? L("Block this user")
                                 : L("Block %@", target.name))
                        }
                        .settingHelp(L("Hides this user's exercises and profile from you everywhere in the app. You can unblock them in Settings under Profile."))
                    }
                }
            }
            .navigationTitle(report.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            // The field's return key inserts a newline rather than closing the
            // keyboard, so scrolling is what puts it away.
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .toolbarHitArea()
                    }
                    .explain(L("Closes this without sending a report."))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: send) {
                        // The spinner takes the word's place rather than sitting
                        // beside it, so the button doesn't change width mid-send.
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Send")
                                .toolbarHitArea()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSend)
                    .explain(L("Sends your report to the developer, along with what it's about, and blocks the user if you turned that on. It stays grayed out until you've written a reason or turned on blocking."))
                }
            }
            // `L(_:)` inside the alert: its buttons are built in the alert's own
            // environment, which the locale set below doesn't reach.
            .alert("Report Not Sent", isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            )) {
                Button(L("OK"), role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
        // A reason that has been written isn't thrown away by a stray swipe down;
        // Cancel is how to leave it. Nor is a report on its way.
        .interactiveDismissDisabled(isSending || !trimmedMessage.isEmpty)
        // Writing the reason is all this sheet is for, so the keyboard is up
        // from the start.
        .onAppear { isWriting = true }
        // Asserted again here: a presentation takes neither the language nor the
        // appearance from the screen it is presented over (see IntroTutorialView).
        .environment(\.locale, appLanguage.language.locale)
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
    }

    /// Posts the report, then closes the sheet; the toast lives above the tabs, so
    /// the confirmation outlives the sheet. A report the server didn't take
    /// leaves the sheet exactly as it was, block switch included: nothing is
    /// blocked until the developer has heard about it.
    private func send() {
        guard canSend else { return }
        isWriting = false
        isSending = true
        let message = trimmedMessage
        let report = report
        let target = blocksUser ? report.blockTarget : nil
        Task {
            let sent = await report.send(message, blocking: target != nil)
            isSending = false
            guard sent else {
                failure = L("Your report couldn't be sent. Check your connection and try again.")
                return
            }
            if let target {
                onBlock(target)
                toasts.show(L("Reported and Blocked!"))
            } else {
                toasts.show(L("Report Sent!"))
            }
            dismiss()
        }
    }
}
