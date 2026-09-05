//
//  FeedbackView.swift
//  Learn2Sing
//
//  The "Request a new Feature/ Report a Bug" category in Settings: a short form
//  the user writes one message in, posted to the same backend the profile and
//  the community exercises live on, where the developer reads it.
//

import SwiftUI

/// What a message is about. The raw values are what the server is told — they
/// travel as the message's `severity` — so they stay English whatever language
/// the app is in; the picker shows them through `L(_:)`. Because they never
/// appear as a literal at a call site, the keys are listed in the localization
/// tooling's `INDIRECT` table (see Tools/Localization/generate.py).
enum FeedbackType: String, CaseIterable, Identifiable {
    case bug = "Bug"
    case featureRequest = "Feature Request"
    case feedback = "Feedback"
    case question = "Question"

    var id: String { rawValue }
}

/// The part of the app a message is about, sent as its `subject`, and localized
/// the same indirect way as `FeedbackType`. Optional: left unanswered it sends
/// an empty subject rather than guessing at one — "Other" is a thing the user
/// picked, not a stand-in for saying nothing.
enum FeedbackLocation: String, CaseIterable, Identifiable {
    case home = "Home"
    case exercises = "Exercises"
    case community = "Community"
    case settings = "Settings"
    case other = "Other"

    var id: String { rawValue }
}

/// Posts the messages written on the feedback screen to the backend.
///
/// One-shot and stateless, unlike ProfileSync and CommunitySync: nothing is
/// mirrored, so there is nothing to keep in step and nothing to remember. A
/// message the server didn't take is simply sent again by the user, from the
/// screen it is still written on.
enum FeedbackSender {
    private static let baseURL = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"

    /// The JSON body the endpoint takes. All four keys are always present; the
    /// two optional fields go as empty strings when they were left blank.
    private struct MessageBody: Encodable {
        var senderEmail: String
        var subject: String
        var severity: String
        var body: String
    }

    /// The server's answer to a message it accepted: a confirmation and the id
    /// it filed the message under. Only the id is of any use here, and only in
    /// the log — there is nothing this app can do with it afterwards.
    private struct MessageReceipt: Decodable {
        var messageId: String?
    }

    /// Sends one message and reports whether the server took it.
    ///
    /// Keyed by the raw Keychain device id — the same id the profile is stored
    /// under (see `DeviceIdentifier` and `ProfileSync`), so a report can be
    /// matched up with the library and settings of whoever wrote it. That id
    /// stays off the *community* endpoints, which list ids back to every other
    /// user, which is what `PublicIdentifier` exists for; this one answers only
    /// the sender, and only about their own message.
    static func send(type: FeedbackType,
                     location: FeedbackLocation?,
                     message: String,
                     email: String) async -> Bool {
        let body = MessageBody(
            senderEmail: email,
            subject: location?.rawValue ?? "",
            severity: type.rawValue,
            body: message)
        guard let url = URL(string: "\(baseURL)/message/\(DeviceIdentifier.uuidString)/send"),
              let data = try? JSONEncoder().encode(body)
        else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (answer, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200...299).contains(http.statusCode) else {
                print("FeedbackSender: send failed with status \(http.statusCode)")
                return false
            }
            // The status is what says the message landed; the receipt is read
            // leniently, so a server that changes what it answers with can't
            // turn a sent message into an error on the user's screen.
            let id = (try? JSONDecoder().decode(MessageReceipt.self, from: answer))?.messageId
            print("FeedbackSender: message sent\(id.map { " as \($0)" } ?? "")")
            return true
        } catch {
            print("FeedbackSender: send failed: \(error)")
            return false
        }
    }
}

/// The "Request a new Feature/ Report a Bug" category reached from Settings.
/// Four fields — two of them optional — and a Send button that posts them as one
/// message. Nothing is stored on the device: a sent message is gone from here,
/// and a failed one stays on screen to be sent again.
struct FeedbackView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss

    /// Empty until the user picks one. Required: the type is what sorts a bug
    /// from a wish at the other end, and defaulting it would file every message
    /// that was sent without a thought under whichever one was chosen here.
    @State private var typeRaw = ""
    /// Empty for "didn't say", which is a valid answer — the field is optional.
    @State private var locationRaw = ""
    @State private var message = ""
    @State private var email = ""

    @State private var isSending = false
    /// Set when the server didn't take the message, and shown in an alert. The
    /// form keeps everything that was written, so Send can just be tapped again.
    @State private var failure: String?

    @FocusState private var isWriting: Bool

    private var type: FeedbackType? { FeedbackType(rawValue: typeRaw) }
    private var location: FeedbackLocation? { FeedbackLocation(rawValue: locationRaw) }
    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// An address that can't be replied to is worse than none at all — the user
    /// would be left waiting for an answer that never comes — so a malformed one
    /// holds the message back rather than travelling with it. Blank is fine.
    private var isEmailUsable: Bool {
        trimmedEmail.isEmpty || Self.looksLikeEmail(trimmedEmail)
    }

    private var canSend: Bool {
        type != nil && !trimmedMessage.isEmpty && isEmailUsable
    }

    var body: some View {
        Form {
            Section {
                // The two required fields are marked with an asterisk, added
                // beside the label rather than written into the key, so every
                // language keeps its own word and only the marker is appended.
                Picker(selection: $typeRaw) {
                    Text("Not set").tag("")
                    ForEach(FeedbackType.allCases) { type in
                        Text(L(type.rawValue)).tag(type.rawValue)
                    }
                } label: {
                    Text("Type") + Text(verbatim: " *")
                }
                .setting(.feedbackType)

                Picker("Where in the app", selection: $locationRaw) {
                    Text("Not set").tag("")
                    ForEach(FeedbackLocation.allCases) { location in
                        Text(L(location.rawValue)).tag(location.rawValue)
                    }
                }
                .setting(.feedbackLocation)
            }

            Section {
                TextField("What would you like to say?", text: $message, axis: .vertical)
                    .lineLimit(5...15)
                    .focused($isWriting)
                    .setting(.feedbackMessage)
            } header: {
                Text("Message") + Text(verbatim: " *")
            }

            Section {
                // The placeholder goes through `L(_:)` rather than being handed
                // over as a literal: a `LocalizedStringKey` is parsed as
                // markdown, which turns anything shaped like an address into an
                // autolink — the placeholder came out as blue link text.
                TextField(L("name@example.com"), text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    // The one field whose explanation is written out below it
                    // rather than held for, so it is marked for the search
                    // without a bubble of its own.
                    .settingAnchor(.feedbackEmail)
            } header: {
                Text("E-Mail")
            } footer: {
                // The one field whose explanation stays on screen rather than
                // hiding behind `settingHelp`'s hold: that an address is optional
                // is what stops someone leaving without sending, so it can't wait
                // to be asked for. A malformed address adds a line below it, so
                // the note itself doesn't move when the warning appears.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Optional, and only needed if you'd like an answer. Left blank, your message is still read.")
                    if !isEmailUsable {
                        Text("That doesn't look like an e-mail address.")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Button(action: send) {
                    HStack {
                        Spacer()
                        // The spinner takes the label's place rather than sitting
                        // beside it, so the row doesn't change width mid-send.
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                        Spacer()
                    }
                }
                .disabled(!canSend || isSending)
                .setting(.feedbackSend)
            } footer: {
                // The legend for the asterisks above stays put at the top, so
                // the line below it — which says which of the two required
                // fields the greyed-out button is still waiting on — can come
                // and go without moving it. The type is asked for first because
                // it's the one a user is likelier to scroll straight past.
                //
                // `L(_:)` rather than a literal: a `LocalizedStringKey` is
                // parsed as markdown, where a leading `*` is emphasis waiting
                // for its closing pair.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("*Required Fields"))
                    if type == nil {
                        Text("Choose a type before sending.")
                    } else if trimmedMessage.isEmpty {
                        Text("Write a message before sending.")
                    }
                }
            }
        }
        .navigationTitle(L("Request a new Feature/ Report a Bug"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.feedback)
        .stableTopEdgeFade()
        // The message field's return key inserts a newline rather than closing
        // the keyboard, so scrolling is what puts it away.
        .scrollDismissesKeyboard(.interactively)
        .alert("Message Not Sent", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    /// Posts what's on screen, then leaves — the toast lives above the tabs, so
    /// the confirmation outlives this screen being popped (see `ToastCenter`).
    /// A message the server didn't take leaves the form exactly as it was.
    private func send() {
        guard let type, canSend, !isSending else { return }
        isWriting = false
        isSending = true
        let message = trimmedMessage
        let email = trimmedEmail
        let location = location
        Task {
            let sent = await FeedbackSender.send(
                type: type, location: location, message: message, email: email)
            isSending = false
            guard sent else {
                failure = L("Your message couldn't be sent. Check your connection and try again.")
                return
            }
            toasts.show(L("Message Sent!"))
            dismiss()
        }
    }

    /// Whether `address` is shaped like an e-mail address: something, an `@`,
    /// then a dotted domain, with no spaces anywhere. Deliberately about as
    /// strict as a mail app's own check — the point is to catch a typo or a
    /// phone number typed into the wrong field, not to rule on what the mail
    /// standard allows.
    private static func looksLikeEmail(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."), dot > domain.startIndex,
              domain.index(after: dot) < domain.endIndex
        else { return false }
        return !address.contains(where: \.isWhitespace)
    }
}
