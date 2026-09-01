//
//  ProfileView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 05.07.26.
//

import SwiftUI
import PhotosUI

/// The user's profile, persisted as JSON in the app's documents directory.
/// The same JSON (with the exercise library embedded) is what ProfileSync
/// uploads to and restores from the server.
struct UserProfile: Codable {
    var username: String = ""
    var deviceID: String = ""
    /// What the user writes about themselves on the profile screen. Optional so
    /// profiles written before the field existed still decode.
    var profileDescription: String? = nil
    /// Whether this user's join date may be shown publicly. Optional so profiles
    /// written before the toggle existed still decode.
    var joinDatePublic: Bool? = nil
    /// When this user joined, as seconds since 1970. Stamped once, on the first
    /// launch that finds it missing (see `ProfileSync.stampJoinDateIfNeeded`),
    /// and carried forward unchanged from then on. Optional so profiles written
    /// before it existed still decode — and so that first launch can tell.
    var joinedAt: Double? = nil
    /// Snapshot of the Exercises tab (exercises, categories, MIDI patterns,
    /// text labels). Optional so profiles written before sync existed decode.
    var exercises: ExerciseBundle? = nil
    /// The Home tab's category display order. Optional so profiles written
    /// before the order was synced still decode.
    var homeCategoryOrder: [String]? = nil
    /// Public ids (lowercase UUID strings) of the Community exercises this user
    /// has liked, so the hearts stay filled across launches and reinstalls.
    /// Owned by CommunitySync; optional so older profiles still decode.
    var likedExercises: [String]? = nil
    /// Public ids (lowercase UUID strings) of the Community exercises this user
    /// has downloaded, so a second download — including after a reinstall —
    /// doesn't count towards the exercise's download total again. Owned by
    /// CommunitySync; optional so older profiles still decode.
    var downloadedExercises: [String]? = nil
    /// The Home tab's "Routines" category: the user's routines in display order.
    /// Optional so profiles written before routines were synced still decode.
    var routines: [Routine]? = nil
    /// The Home tab's "Favourites" category: the favourited exercise ids in
    /// display order. Optional so profiles written before favourites were synced
    /// still decode.
    var favourites: [UUID]? = nil
    /// Every exercise's recorded scores — what the score chart draws — keyed by
    /// exercise UUID string. Optional so profiles written before scores were
    /// synced still decode.
    var scores: [String: ScoreHistoryDoc]? = nil
    /// How long was practised on each day — what the Home tab's calendar draws —
    /// as day number and seconds interleaved, `[d₀, s₀, d₁, s₁, …]`. Optional so
    /// profiles written before the calendar existed still decode.
    var practice: [Int]? = nil
    /// The Settings tab's settings, bar the language. Optional so profiles written
    /// before settings were synced still decode.
    var settings: UserSettings? = nil
    /// How hard an exercise the singer can handle, 0-100 — what the Home tab's
    /// suggestions are pitched at, and the stars on its recommendation card. It
    /// is worked out on the device from the scores and the server's
    /// difficulties (see SkillLevel), and carried here so a reinstall opens at
    /// the level it left off at. Optional so profiles written before it existed
    /// still decode.
    var skillLevel: Double? = nil

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile.json")
    }

    /// Loads the stored profile (or a fresh one) and stamps in the device ID,
    /// a UUID kept in the Keychain so it survives reinstalls, plus the live
    /// Home category order, which lives in UserDefaults.
    static func load() -> UserProfile {
        var profile = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) }
            ?? UserProfile()
        profile.deviceID = DeviceIdentifier.uuidString
        profile.homeCategoryOrder = HomeCategories.stored
        return profile
    }

    /// Fills in the parts of the profile that live outside the profile file: the
    /// exercise library, the Home tab's category order, routines and favourites,
    /// every exercise's score history, the practice calendar, the settings, and
    /// the singer's skill level. Used for both the copy ProfileSync uploads and
    /// the file the profile screen shares.
    mutating func snapshot(_ store: ExerciseStore) {
        exercises = store.exportBundle()
        homeCategoryOrder = HomeCategories.stored
        routines = store.routines
        favourites = store.favourites
        let histories = ScoreHistory.all().mapValues(ScoreHistoryDoc.init)
        scores = histories.isEmpty ? nil : histories
        practice = PracticeLog.doc()
        settings = UserSettings.capturingCurrent(store: store)
        skillLevel = SkillLevelStore.shared.level
    }

    func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

    func save() {
        try? jsonData()?.write(to: Self.fileURL, options: .atomic)
    }
}

struct ProfileView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @State private var profile: UserProfile
    /// What the username field shows, which is not the same thing as the name
    /// this user has: a typed name only moves into the profile once the server
    /// has taken it (see `commitUsername`).
    @State private var typedUsername: String
    /// A rename the server refused, if any. The message is shown only while the
    /// field still holds that name, so editing it away clears the message and
    /// typing it back brings it up again without another call.
    @State private var refusedUsername: RefusedUsername?
    /// The name currently on the wire, so one rename isn't posted twice: leaving
    /// the screen resigns the field's focus *and* dismisses the view, and either
    /// on its own is reason enough to commit.
    @State private var claimingUsername: String?
    @FocusState private var isEditingUsername: Bool
    /// What the description field shows. Like the username it is committed when
    /// the field is finished with rather than per keystroke — every commit
    /// rewrites the profile file, which carries the whole exercise library.
    @State private var typedDescription: String
    @FocusState private var isEditingDescription: Bool
    @State private var joinDatePublic: Bool
    /// This device's profile picture. Its own store rather than part of the
    /// profile file — see `ProfilePictureStore` for why it is kept out of the
    /// document `ProfileSync` uploads.
    @ObservedObject private var picture = ProfilePictureStore.shared
    /// The photo being picked, cleared again as soon as it has been read.
    @State private var pickedPhoto: PhotosPickerItem?
    /// Whether a picked photo is still being scaled and encoded. It happens off
    /// the main thread and takes a moment at 1024px, so the row says so.
    @State private var isPreparingPicture = false
    @State private var isAdjustingPicture = false
    /// Set when a picked photo couldn't be read or encoded at all.
    @State private var pictureFailed = false

    /// A refused rename: the name as typed, so the message can follow the field,
    /// and the name the server named in its error, which is what it shows. The
    /// two differ if the server ever matches names less strictly than byte for
    /// byte — the taken name it reports is the one worth naming.
    private struct RefusedUsername {
        var typed: String
        var reported: String
    }

    init() {
        let profile = UserProfile.load()
        _profile = State(initialValue: profile)
        _typedUsername = State(initialValue: profile.username)
        _typedDescription = State(initialValue: profile.profileDescription ?? "")
        _joinDatePublic = State(initialValue: profile.joinDatePublic ?? false)
    }

    var body: some View {
        Form {
            Section {
                // One row rather than four: the buttons stand in a column of
                // their own, each still a list row tall, with the picture
                // alongside the lot of them instead of above.
                HStack(spacing: 16) {
                    VStack(spacing: 0) {
                        PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                            // Spelled out either way rather than picked with a ternary:
                            // the string extractor keys on the literal that follows
                            // `Label(`, and would walk straight past both of these.
                            if picture.thumb == nil {
                                Label("Choose Photo", systemImage: "photo")
                                    .pictureButtonRow()
                            } else {
                                Label("Change Photo", systemImage: "photo")
                                    .pictureButtonRow()
                            }
                        }
                        .buttonStyle(.plain)
                        // A plain button draws its label in the primary colour,
                        // and one that shares a row with others has to be plain
                        // — see `pictureButtonRow` — so the tint is put back by
                        // hand, greyed while a picked photo is being prepared.
                        .foregroundStyle(isPreparingPicture ? AnyShapeStyle(.secondary)
                                                            : AnyShapeStyle(Color.accentColor))
                        .disabled(isPreparingPicture)
                        .explain(L("Picks a picture from your photos to show on your public profile."))

                        if picture.thumb != nil {
                            Divider()
                            Button {
                                adjustPicture()
                            } label: {
                                Label("Adjust Picture", systemImage: "crop")
                                    .pictureButtonRow()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .explain(L("Drag and pinch to choose what shows in the circle."))

                            Divider()
                            Button(role: .destructive) {
                                picture.removePicture()
                            } label: {
                                Label("Remove Photo", systemImage: "trash")
                                    .pictureButtonRow()
                            }
                            // The destructive role only reddens a *row's* title,
                            // and this is no longer a row of its own.
                            .buttonStyle(.plain)
                            .dangerRow()
                            .explain(L("Takes your picture off your profile. The photo stays in your photo library."))
                        }
                    }

                    ProfileAvatar(image: picture.thumb, side: 110)
                        // Only felt before a picture has been chosen, where the
                        // one button left is shorter than the circle and it is
                        // the circle that sets the row's height.
                        .padding(.vertical, 8)
                        // Tapping the picture itself is the quickest way to the
                        // thing most people come back to change.
                        .onTapGesture { if picture.thumb != nil { adjustPicture() } }
                        .explain(L("How your picture looks to everyone else. Tap it to move and zoom it."))
                        .overlay {
                            if isPreparingPicture {
                                ProgressView()
                                    .controlSize(.large)
                                    .padding(20)
                                    .background(.ultraThinMaterial, in: .circle)
                            }
                        }
                }
                // The buttons stand a list row tall by themselves, so the row
                // they are in adds nothing on top; the horizontal inset is the
                // one a row would have had, so the first button's words line up
                // with the fields in the sections below.
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            } header: {
                Text("Profile Picture")
            } footer: {
                if pictureFailed {
                    Text("That photo could not be used.")
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField("Username", text: $typedUsername)
                    .autocorrectionDisabled()
                    .focused($isEditingUsername)
                    .onSubmit { commitUsername() }
                    .settingHelp(L("The name shown beside the exercises you share. No two users can have the same one."))
            } header: {
                Text("Username")
            } footer: {
                if let refused = refusedUsername, refused.typed == typedUsername {
                    Text(L("Username \"%@\" is not available", refused.reported))
                        .foregroundStyle(.red)
                }
            }

            Section("Profile Description") {
                TextField("Write something about yourself", text: $typedDescription, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($isEditingDescription)
                    .settingHelp(L("A few words about yourself, shown at the top of your profile in the Community tab."))
            }

            Section {
                Toggle("Make your join date public", isOn: $joinDatePublic)
                    .onChange(of: joinDatePublic) { _, isPublic in
                        save { $0.joinDatePublic = isPublic }
                    }
                    .settingHelp(L("Shows other users how long you have had the app, under your profile description."))
            }
        }
        .navigationTitle(L("Profile"))
        .navigationBarTitleDisplayMode(.inline)
        .stableTopEdgeFade()
        // Swiping down over the keyboard puts it away, like everywhere else.
        .scrollDismissesKeyboard(.interactively)
        .onAppear { profile.save() }
        // A reinstall gets the picture back off this user's own public profile
        // before anything on this screen can publish over it — every edit here
        // rewrites that document, picture and all.
        .task { await picture.restoreIfNeeded() }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pictureFailed = false
            isPreparingPicture = true
            Task {
                var used = false
                if let data = try? await item.loadTransferable(type: Data.self) {
                    used = await picture.setPicture(from: data)
                }
                isPreparingPicture = false
                pictureFailed = !used
                pickedPhoto = nil
            }
        }
        .sheet(isPresented: $isAdjustingPicture) {
            if let full = picture.full {
                ProfilePictureEditor(image: full, alignment: picture.alignment) { alignment in
                    Task { await picture.setAlignment(alignment) }
                }
            }
        }
        // A rename is checked when it is finished rather than per keystroke: a
        // name passes through other people's names while being typed, and the
        // check is a POST that takes the name it asks about.
        .onChange(of: isEditingUsername) { _, editing in
            if !editing { commitUsername() }
        }
        .onChange(of: isEditingDescription) { _, editing in
            if !editing { commitDescription() }
        }
        // Leaving with the keyboard still up finishes the edit too.
        .onDisappear {
            commitUsername()
            commitDescription()
        }
    }

    /// Offers the typed name to the server, which is what decides whether it is
    /// free — there is no separate check, the POST that claims a name is the
    /// same one that finds out (see `CommunitySync.claimUsername(_:)`). Only a
    /// name the server takes is saved, so one somebody else already has never
    /// becomes this user's: the field goes on showing it, with the message
    /// underneath, until it is edited into a name that is free.
    private func commitUsername() {
        let name = typedUsername
        guard name != profile.username else {
            refusedUsername = nil
            return
        }
        // Already asked about this one: it is either on the wire or known taken.
        guard name != claimingUsername, name != refusedUsername?.typed else { return }
        claimingUsername = name
        Task {
            let result = await CommunitySync.shared.claimUsername(name)
            // A later edit asked about a different name while this one was on
            // the wire; that one owns the field and the message now.
            guard claimingUsername == name else { return }
            claimingUsername = nil
            switch result {
            case .accepted:
                refusedUsername = nil
                save(username: name)
            case .taken(let taken):
                refusedUsername = RefusedUsername(typed: name, reported: taken)
            case .failed:
                // No answer either way, so nothing to hold against the name:
                // renaming offline works as it always did, and the name is
                // re-posted on the next upload and every launch until it lands.
                refusedUsername = nil
                save(username: name)
            }
        }
    }

    /// Opens the move-and-scale editor, decoding the whole picture first — the
    /// round rendition the screens draw is far too small to align against.
    private func adjustPicture() {
        picture.loadFull()
        guard picture.full != nil else { return }
        isAdjustingPicture = true
    }

    /// Writes the typed description into the profile once the field is finished
    /// with. Unlike a rename there is nothing to claim, so it is simply saved.
    private func commitDescription() {
        let text = typedDescription
        guard text != (profile.profileDescription ?? "") else { return }
        save { $0.profileDescription = text }
    }

    /// Puts an accepted name in the profile file and sends it on to the server's
    /// copy of the profile.
    private func save(username: String) {
        save { $0.username = username }
    }

    /// Applies one edit to the profile file and sends it on to the server's copy.
    /// Written onto a freshly loaded profile rather than this screen's snapshot,
    /// which the Community tab may have added a like or a download to since it
    /// was taken — and then onto the snapshot too, so the screen agrees with it.
    ///
    /// Both syncs are asked to catch up: the private backup carries every field,
    /// while the description and the join date are also published — under the
    /// public user id, never the device one — for the Community tab to show on
    /// this user's profile (see `CommunitySync.uploadPublicProfile`).
    private func save(_ edit: (inout UserProfile) -> Void) {
        var stored = UserProfile.load()
        edit(&stored)
        stored.save()
        edit(&profile)
        ProfileSync.shared.scheduleUpload()
        CommunitySync.shared.scheduleUpload()
    }
}

private extension View {
    /// Lays one of the profile picture's buttons out the way the list row it
    /// used to be was laid out: a row's height, the full width of the button
    /// column, and a tap anywhere along that width and not on the words alone.
    ///
    /// The three of them share one row with the picture now, which is why they
    /// have to be `.plain`: several default-styled buttons in a single list row
    /// fire together. A row draws no separators between what is inside it
    /// either, hence the `Divider`s.
    func pictureButtonRow() -> some View {
        modifier(PictureButtonRow())
    }
}

private struct PictureButtonRow: ViewModifier {
    /// The height a row on this screen stands at: that of the username field
    /// beneath it, and of the three rows these buttons used to be. The row they
    /// live in now has its own vertical insets zeroed, so this is what gives the
    /// section its height — scaled, so a larger Dynamic Type moves these buttons
    /// the way it moves the rows around them.
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 52

    func body(content: Content) -> some View {
        content
            // The column is only as wide as what is left beside the picture, and
            // the longest of the three reads "Настроить изображение" in Russian.
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .contentShape(.rect)
    }
}
