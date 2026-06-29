import SwiftUI
import UniformTypeIdentifiers

/// The "Visuals" hub reached from Settings. For now it has a single entry —
/// Playback — but it's a screen of its own so further visual areas can be added.
struct VisualsHubView: View {
    /// Push the playback-visuals screen onto the shared Settings navigation stack.
    let openPlayback: () -> Void

    var body: some View {
        Form {
            Section {
                Button(action: openPlayback) {
                    HStack {
                        Label("Playback", systemImage: "play.rectangle")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            } footer: {
                Text("Customise how the note-scrolling playback screen looks.")
            }
        }
        .navigationTitle("Visuals")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Customises the look of the playback screen. A live preview at the top — a small
/// square cut-out of the real playback rendering — updates as the controls below
/// are changed, so the effect of each setting is immediately visible.
struct PlaybackVisualsView: View {
    @AppStorage(VisualKeys.noteColor)      private var noteColor      = VisualDefaults.noteColor
    @AppStorage(VisualKeys.noteRoundness)  private var noteRoundness  = VisualDefaults.noteRoundness
    @AppStorage(VisualKeys.verticalZoom)   private var verticalZoom   = VisualDefaults.verticalZoom
    @AppStorage(VisualKeys.horizontalZoom) private var horizontalZoom = VisualDefaults.horizontalZoom
    @AppStorage(VisualKeys.followVertical) private var followVertical = VisualDefaults.followVertical
    @AppStorage(VisualKeys.showLines)      private var showLines      = VisualDefaults.showLines
    @AppStorage(VisualKeys.background)     private var background      = VisualDefaults.background
    @AppStorage(VisualKeys.showKeyboard)   private var showKeyboard   = VisualDefaults.showKeyboard
    @AppStorage(VisualKeys.showPitches)    private var showPitches     = VisualDefaults.showPitches
    @AppStorage(VisualKeys.textColor)      private var textColor      = VisualDefaults.textColor
    @AppStorage(VisualKeys.textFont)       private var textFont       = VisualDefaults.textFont

    /// Saved named templates the user can switch between.
    @StateObject private var templates = VisualTemplateStore()

    /// Naming alert for "Save current as template".
    @State private var isNamingTemplate = false
    @State private var newTemplateName = ""

    /// Share-sheet / file-dialog state for export & import of a single template.
    @State private var exportDocument: ExerciseDocument?
    @State private var exportFilename = "Visual Template"
    @State private var isExportingTemplate = false
    @State private var isImportingTemplate = false
    @State private var templateAlert: String?

    /// Anchors the preview's scrolling clock so the demo notes start at beat 0 when
    /// the screen appears (rather than at the huge absolute timeline value).
    @State private var start = Date()

    /// The settings as currently chosen, rebuilt each render so the preview tracks
    /// every edit live.
    private var settings: VisualSettings {
        VisualSettings(
            noteColor: Color(hex: noteColor),
            noteRoundness: noteRoundness,
            verticalZoom: verticalZoom,
            horizontalZoom: horizontalZoom,
            followNotesVertically: followVertical,
            showHorizontalLines: showLines,
            backgroundColor: Color(hex: background),
            showKeyboard: showKeyboard,
            showPitches: showPitches,
            textColor: Color(hex: textColor),
            textFont: PlaybackFont(rawValue: textFont) ?? .system)
    }

    // Demo content. A short three-note motif repeated many times so the preview can
    // scroll for a long while without running out. The notes sit well above the
    // default centre so "follow notes vertically" visibly recentres them.
    private static let demoPattern: [(pitch: Int, beat: Double)] = [(60, 0), (64, 1), (67, 2)]
    private let demoNotes: [MIDINote] = {
        var ns: [MIDINote] = []
        for k in 0..<200 {
            for note in PlaybackVisualsView.demoPattern {
                ns.append(MIDINote(pitch: note.pitch, beat: Double(k) * 4 + note.beat, length: 0.9))
            }
        }
        return ns
    }()
    private let demoTexts: [MIDIText] = (0..<200).map {
        MIDIText(text: "La", pitch: 70, beat: Double($0) * 4 + 0.15)
    }
    /// Midpoint of the demo notes, used as the centre when following vertically.
    private let demoCenter = Double(60 + 67) / 2

    var body: some View {
        Form {
            templatesSection

            Section {
                preview
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Notes") {
                ColorPicker("Note colour", selection: colorBinding($noteColor), supportsOpacity: false)
                sliderRow("Note roundness", value: $noteRoundness, range: 0...1)
            }

            Section("Zoom & position") {
                sliderRow("Vertical zoom", value: $verticalZoom, range: 0.5...3)
                sliderRow("Horizontal zoom", value: $horizontalZoom, range: 0.4...3)
                Toggle("Follow notes vertically", isOn: $followVertical)
            }

            Section("Background") {
                Toggle("Show horizontal lines", isOn: $showLines)
                if !showLines {
                    ColorPicker("Background colour", selection: colorBinding($background), supportsOpacity: false)
                }
                Toggle("Show keyboard", isOn: $showKeyboard)
                Toggle("Show pitches", isOn: $showPitches)
            }

            Section("Text") {
                ColorPicker("Text colour", selection: colorBinding($textColor), supportsOpacity: false)
                Picker("Text font", selection: $textFont) {
                    ForEach(PlaybackFont.allCases) { font in
                        Text(font.rawValue).tag(font.rawValue)
                    }
                }
            }

            Section {
                Button {
                    exportCurrentTemplate()
                } label: {
                    Label("Export template", systemImage: "square.and.arrow.up")
                }

                Button {
                    isImportingTemplate = true
                } label: {
                    Label("Import template", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Export saves the current visual settings as a template file you can share. Import loads a template file and applies it.")
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .alert("New Template", isPresented: $isNamingTemplate) {
            TextField("Name", text: $newTemplateName)
            Button("Save") { saveCurrentAsTemplate() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Save the current visual settings as a template.")
        }
        .fileExporter(
            isPresented: $isExportingTemplate,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                templateAlert = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $isImportingTemplate,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url),
                      let template = VisualTemplate.decode(from: data) else {
                    templateAlert = "That file isn’t a valid visual template."
                    return
                }
                templates.add(imported: template).apply()
            case .failure(let error):
                templateAlert = "Import failed: \(error.localizedDescription)"
            }
        }
        .alert("Templates", isPresented: Binding(
            get: { templateAlert != nil },
            set: { if !$0 { templateAlert = nil } }
        )) {
            Button("OK", role: .cancel) { templateAlert = nil }
        } message: {
            Text(templateAlert ?? "")
        }
    }

    // MARK: - Templates

    private var templatesSection: some View {
        Section {
            ForEach(templates.templates) { template in
                Button {
                    template.apply()
                } label: {
                    HStack {
                        Text(template.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if template.matchesCurrent {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .onDelete { templates.remove(atOffsets: $0) }

            Button {
                newTemplateName = ""
                isNamingTemplate = true
            } label: {
                Label("Save current as template", systemImage: "plus")
            }
        } header: {
            Text("Templates")
        } footer: {
            Text("Select a template to apply it, or save the current settings as a new one.")
        }
    }

    /// Captures the current settings under the entered name and stores them.
    private func saveCurrentAsTemplate() {
        let name = newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        templates.add(.capturingCurrent(name: name))
    }

    /// Prepares a JSON document of the current settings and presents the share dialog.
    private func exportCurrentTemplate() {
        let current = templates.templates.first(where: \.matchesCurrent)
        let name = current?.name ?? "Custom"
        let template = VisualTemplate.capturingCurrent(name: name)
        guard let data = template.jsonData() else {
            templateAlert = "Could not prepare the template file."
            return
        }
        exportFilename = name
        exportDocument = ExerciseDocument(data: data)
        isExportingTemplate = true
    }

    // MARK: - Preview

    private var preview: some View {
        TimelineView(.animation) { timeline in
            let beat = timeline.date.timeIntervalSince(start) * 0.7   // slow scroll
            Canvas { ctx, size in
                let baseRowH = size.height / CGFloat(hiPitch - loPitch + 1)
                let rowH = baseRowH * CGFloat(settings.verticalZoom)
                let beatPx = 40 * CGFloat(settings.horizontalZoom)
                let pW: CGFloat = settings.showKeyboard ? 38 : 0
                let center = settings.followNotesVertically
                    ? demoCenter
                    : Double(hiPitch + loPitch) / 2
                let layout = SceneLayout(size: size, pianoW: pW, rowH: rowH, beatPx: beatPx,
                                         playheadX: size.width / 3, centerPitch: center)
                // A gently bobbing dot so the singer indicator is visible too.
                let singer = demoCenter + 2.5 * sin(beat * 1.6)
                drawPlaybackScene(ctx: ctx, layout: layout, beat: beat,
                                  notes: demoNotes, texts: demoTexts,
                                  trailPath: Path(), singerPitch: singer, settings: settings)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15)))
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: value, in: range)
        }
    }

    /// Bridges a hex-string @AppStorage value to the `Color` a ColorPicker expects.
    private func colorBinding(_ raw: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hex: raw.wrappedValue) },
                set: { raw.wrappedValue = $0.hexString })
    }
}
