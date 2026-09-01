import SwiftUI
import UIKit

/// What a row draws. Almost every row is an exercise — its name, with its MIDI
/// pattern on the trailing edge. The Home tab's two cards are the exceptions: a
/// view of its own filling the row, with no name and no swipe actions. What each
/// one draws rides along here so the list notices when it changes and redraws
/// the cell.
enum ExerciseListRowContent: Equatable {
    case exercise
    /// The practice calendar: the days it draws, and the daily practice time
    /// their squares are measured against (Settings ▸ Exercises). The goal rides
    /// along so that changing it reaches the cell as a changed row.
    case practiceCalendar([PracticeDay], goalMinutes: Int)
    /// The recommendation card, naming the category most of the recommended
    /// exercises come from and the singer's own level (0-100 — see
    /// SkillLevelStore). Shown in place of the "Recommended" list when
    /// Settings ▸ Exercises says so.
    case recommendation(category: String, skill: Double)

    /// Whether a tap on the row is the list's to report. The calendar answers
    /// its own taps — a tap on it means the square it landed on — while every
    /// other row opens something.
    var isSelectable: Bool {
        if case .practiceCalendar = self { return false }
        return true
    }
}

/// One row of the exercise list: the exercise plus its MIDI pattern (a single
/// repetition — the stored notes, before any repeat/transpose playback settings),
/// drawn as a thumbnail on the row's trailing edge.
struct ExerciseListRow: Equatable {
    var exercise: Exercise
    var pattern: [MIDINote]
    /// What the row draws in place of the exercise name — an exercise, unless
    /// the row is one of the list's own (the Home tab's cards).
    var content: ExerciseListRowContent = .exercise
    /// Shown in grey between the name and the pattern thumbnail (Community tab
    /// only — nil hides it).
    var uploaderName: String? = nil
    /// nil hides the selection mark; true/false draws a filled/empty circle on
    /// the row's leading edge (the routine exercise picker).
    var isSelected: Bool? = nil
    /// Title and symbol of the leading "Settings" swipe action, so rows that
    /// aren't exercises (routines on the Home tab) can label it differently.
    var swipeActionTitle = L("Settings")
    var swipeActionImage = "slider.horizontal.3"
    /// true adds a trailing "Delete" swipe action (routines on the Home tab).
    var showsDelete = false
    var id: UUID { exercise.id }
}

/// One visible group in the exercise list: a category and the rows shown for it.
/// `category` is "" for the uncategorized group, which renders without a header.
struct ExerciseListSection: Equatable {
    var category: String
    var isCollapsed: Bool
    /// Number of exercises in the category, including hidden ones — shown in the
    /// header while collapsed (when `items` is empty) and always when zero, so
    /// empty categories don't look like they lost their contents.
    var totalCount: Int
    var items: [ExerciseListRow]
    /// false keeps the exercise count out of the header entirely, even while
    /// collapsed (Home tab).
    var showsCount = true
    /// true puts a + button in the header, right after the category name
    /// (Routines on the Home tab). Taps arrive via the list's `onAdd`.
    var showsAdd = false
    /// What holding that + button explains. nil leaves it without help, the way
    /// every other press-and-hold target that has nothing to say does.
    var addHelp: String? = nil
    /// false drops the collapse chevron from the header, for sections that only
    /// label a group and can't be collapsed (the Community search results).
    var showsChevron = true
    /// What the header reads, when it isn't the category name itself. `category`
    /// stays the English identifier the sections are diffed and grouped by, so a
    /// section whose heading is a fixed piece of UI text (the Community search
    /// results) passes its translated heading here instead.
    var displayName: String? = nil
    /// false keeps the section out of drag & drop entirely: its rows can't be
    /// lifted, and nothing can be dropped into it — for sections whose order the
    /// user doesn't get to arrange (Home's Recent and Recommended, both computed).
    var allowsReorder = true
}

/// The normal-mode exercise list. This is intentionally NOT a SwiftUI List: a
/// List can never commit an internal drag onto another row or section (row-level
/// drop modifiers aren't consulted for List-internal drags, `.onDrag` crashes on
/// multi-section lists, and per-section `.onMove` can't cross sections). It is a
/// UICollectionView in the same insetGrouped list style SwiftUI's List is backed
/// by — same appearance — with drag & drop driven directly through UIKit's
/// drag/drop delegates: an exercise can be dragged to reorder within its category
/// or dropped into another one (including onto a collapsed category's header) —
/// unless the list keeps moves in their section, in which case a drag can only
/// rearrange the section it started in (the Home tab).
struct ExerciseCollectionList: UIViewControllerRepresentable {
    var sections: [ExerciseListSection]
    /// Row taps: the exercise, and the category of the section it was tapped in —
    /// which the Home tab needs, since the same exercise can be listed under
    /// several of its categories at once.
    var onSelect: (UUID, String) -> Void
    /// Tap on a row's grey uploader name (Community tab). nil leaves the name inert.
    var onSelectUploader: ((String) -> Void)? = nil
    /// Pull-to-refresh handler (Community tab); the spinner stays until it
    /// returns. nil (the other tabs) installs no refresh control at all.
    var onRefresh: (() async -> Void)? = nil
    /// nil hides the leading "Settings" swipe action (Community tab).
    var onSettings: ((UUID) -> Void)? = nil
    /// Trailing "Delete" swipe on rows with `showsDelete`. Only asked to confirm —
    /// the row stays until the store update comes back through `sections`.
    var onDelete: ((UUID) -> Void)? = nil
    var onToggleCollapse: (String) -> Void = { _ in }
    var onHeaderLongPress: () -> Void = {}
    /// Tap on a section header's + button (sections with `showsAdd`).
    var onAdd: ((String) -> Void)? = nil
    /// Tap on a square of a `.practiceCalendar` row, or nil for one that landed
    /// on no square. The bubble it puts up is drawn over the list rather than
    /// inside the row, which would clip it — so the screen showing the list is
    /// the one that draws it, and this is how it hears about the tap. Called
    /// with nil as the list is scrolled too, since a bubble drawn outside the
    /// list can't travel with the square it points at.
    var onCalendarSelect: ((PracticeCalendarSelection?) -> Void)? = nil
    /// (exercise, newCategory, idOfExerciseItNowPrecedes — nil appends).
    /// nil disables drag & drop entirely (Community tab).
    var onMove: ((UUID, String, UUID?) -> Void)? = nil
    /// true as a row is lifted, false as the drag ends (dropped or cancelled), so
    /// the screen around the list can show that it's being rearranged.
    var onDragChange: ((Bool) -> Void)? = nil
    /// true refuses every drop outside the section the drag was lifted from, so
    /// each section is its own separate ordered list (the Home tab, where the
    /// categories are different kinds of thing and a favourite dropped into
    /// "Recent" would mean nothing).
    var movesStayInSection = false
    /// Called as the list runs out of rows to scroll through — fewer than
    /// `loadMoreThreshold` of them left below the ones on screen — so the
    /// Community tab can fetch its next page. May be called many times over
    /// before that page arrives. nil (every other tab, whose lists are complete)
    /// never asks for more.
    var onLoadMore: (() -> Void)? = nil
    /// How few rows may be left below the bottom of the screen before `onLoadMore`
    /// is called.
    var loadMoreThreshold = 30
    /// true starts the list scrolled just past the navigation bar's search drawer,
    /// so the field only appears when the user pulls down (Exercises tab).
    var hidesSearchBarInitially = false
    /// Set to an exercise to scroll it into view and flash it once — how a
    /// just-created exercise is pointed out when its settings screen is popped
    /// (Exercises tab). Each id is acted on only once.
    var highlightedID: UUID? = nil
    /// Captured when SwiftUI rebuilds this view. Cell text and headers are
    /// translated as they're written into UIKit, and the section data itself is
    /// unchanged by a language switch, so the controller is told separately.
    var language = LanguageManager.shared.language

    func makeUIViewController(context: Context) -> ExerciseListController {
        let controller = ExerciseListController()
        apply(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: ExerciseListController, context: Context) {
        apply(to: controller)
    }

    private func apply(to controller: ExerciseListController) {
        controller.onSelect = onSelect
        controller.onSelectUploader = onSelectUploader
        controller.onRefresh = onRefresh
        controller.onSettings = onSettings
        controller.onDelete = onDelete
        controller.onToggleCollapse = onToggleCollapse
        controller.onHeaderLongPress = onHeaderLongPress
        controller.onAdd = onAdd
        controller.onCalendarSelect = onCalendarSelect
        controller.onMove = onMove
        controller.onDragChange = onDragChange
        controller.movesStayInSection = movesStayInSection
        controller.onLoadMore = onLoadMore
        controller.loadMoreThreshold = loadMoreThreshold
        controller.hidesSearchBarInitially = hidesSearchBarInitially
        controller.setLanguage(language)
        controller.setSections(sections, animated: true)
        if let highlightedID {
            controller.highlight(highlightedID)
        }
        // Every update is a chance to notice that the list is running out of rows
        // below the screen — including the one that follows a page finishing
        // loading, which is where a list parked at its end would otherwise sit
        // waiting to be scrolled (see `checkLoadMore`).
        controller.checkLoadMore()
    }
}

/// The navigation-bar title of a tab whose list can be rearranged by dragging:
/// the tab's own title, which for as long as a row is held becomes an accent-
/// coloured "Reordering" so it's plain that letting go will move it.
///
/// The two directions are deliberately not mirror images. Picking a row up is
/// the moment worth announcing, so "Reordering" springs out of nothing —
/// small, ballooning to about twice its settled size, dropping back — while
/// letting go is just a quick cross-fade back to the tab's own title, the same
/// understated switch it always was.
///
/// A `.principal` toolbar item rather than `.navigationTitle`, which is UIKit's
/// own label and can't be recoloured. The views set both: the title still names
/// the back button of anything they push.
struct ReorderableListTitle: View {
    var title: String
    var isDragging: Bool

    /// How small "Reordering" sits before it pops. Small enough that the growth
    /// is the eye-catching part; the word is still fading in at that point, so
    /// it reads as appearing from nothing rather than as a shrunken label.
    private let restingScale: CGFloat = 0.4

    /// How far past its settled size the word sails at the top of the pop —
    /// about double, so the change of title is impossible to miss. A spring on
    /// its own can't throw a value that far past its target (the overshoot it
    /// can muster from a positive starting scale is a few per cent, which was
    /// easy to miss entirely), hence the hand-drawn arc below.
    private let peakScale: CGFloat = 2

    /// Counts pickups rather than following `isDragging`, so the arc only ever
    /// runs in the growing direction. Letting go leaves the word parked at full
    /// size to fade out on its own, exactly as before, and the next pickup
    /// re-arms `restingScale` at the start of its own run — while the word is
    /// invisible, so the reset is never seen.
    @State private var popCount = 0

    var body: some View {
        // Both words are always laid out, one on top of the other, and only their
        // opacity changes. Swapping the string of a single Text instead makes the
        // title jump left for a frame as the label resizes around the longer word
        // mid-fade; stacked, the frame is the wider of the two from the start and
        // nothing moves. The pop is a `scaleEffect`, which likewise doesn't touch
        // the layout, so the other title underneath stays put while it plays.
        ZStack {
            Text(title)
                .foregroundStyle(Color.primary)
                .opacity(isDragging ? 0 : 1)
                .animation(.easeInOut(duration: 0.15), value: isDragging)
                .accessibilityHidden(isDragging)
            Text(L("Reordering"))
                .foregroundStyle(Color.accentColor)
                // Faster than the outgoing title's fade so the word is legible
                // early and the growth is the part that's actually watched.
                .opacity(isDragging ? 1 : 0)
                .animation(isDragging
                           ? .easeOut(duration: 0.12)
                           : .easeInOut(duration: 0.15),
                           value: isDragging)
                // The pop: out of nothing, up past double size, then pulled
                // back down to the size it keeps for as long as the row is
                // held — the shape a bouncy spring drew before, with an
                // overshoot big enough to actually catch the eye. The settle
                // is a spring, so it still dips a shade under full size and is
                // drawn back up rather than stopping dead.
                .keyframeAnimator(initialValue: restingScale,
                                  trigger: popCount) { view, scale in
                    view.scaleEffect(scale)
                } keyframes: { _ in
                    LinearKeyframe(peakScale, duration: 0.18, timingCurve: .easeOut)
                    SpringKeyframe(1, duration: 0.34,
                                   spring: Spring(duration: 0.3, bounce: 0.3))
                }
                .accessibilityHidden(!isDragging)
        }
        .font(.headline)
        .onChange(of: isDragging) { _, dragging in
            if dragging { popCount += 1 }
        }
    }
}

/// Diffable item identity. A bare exercise UUID can't be the identifier: the
/// same exercise may legitimately appear in more than one section (a
/// recently-played exercise that's also a favourite, on the Home tab), and a
/// diffable snapshot requires globally-unique item identifiers. With a bare UUID
/// the later section's copy wins, so collapsing that section makes the row jump
/// to the other one. Pairing the UUID with its section keeps each copy distinct.
nonisolated private struct ItemID: Hashable {
    var section: String
    var id: UUID
}

final class ExerciseListController: UIViewController {
    var onSelect: ((UUID, String) -> Void)?
    var onSelectUploader: ((String) -> Void)?
    var onRefresh: (() async -> Void)?
    var onSettings: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onToggleCollapse: ((String) -> Void)?
    var onHeaderLongPress: (() -> Void)?
    var onAdd: ((String) -> Void)?
    var onCalendarSelect: ((PracticeCalendarSelection?) -> Void)?
    var onMove: ((UUID, String, UUID?) -> Void)?
    var onDragChange: ((Bool) -> Void)?
    var movesStayInSection = false
    var onLoadMore: (() -> Void)?
    var loadMoreThreshold = 30
    var hidesSearchBarInitially = false

    /// Set once the initial scroll past the search drawer has been performed, so
    /// later layout passes leave the user's scroll position alone.
    private var hasHiddenSearchBar = false

    /// The language the visible cells and headers were rendered in.
    private var language = LanguageManager.shared.language

    /// Redraw everything after a language change. The sections are identical —
    /// exercise names are stored in English and translated on the way into the
    /// cell — so the diffable data source has to be told to reconfigure by hand.
    func setLanguage(_ new: AppLanguage) {
        guard new != language else { return }
        language = new
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        updateVisibleHeaders(animated: false)
    }

    private var sections: [ExerciseListSection] = []
    private var rowsByID: [UUID: ExerciseListRow] = [:]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, ItemID>!
    /// Sections handed over while a drag was in flight; deferred because mutating
    /// the layout mid-drag cancels the lift (and crashes SwiftUI's equivalent).
    private var pendingSections: [ExerciseListSection]?
    private var isPerformingDrop = false
    /// Where the drop would land, worked out as the finger moves and kept for the
    /// drop itself. It has to be worked out live: it takes the list as it looks
    /// mid-drag to tell the last spot of a category from the one before it, and
    /// by the time the row is let go the list has already sprung back.
    private var liveDropTarget: DropTarget?
    /// The row in the air. For as long as the drag lasts the list stops listing
    /// it where it belongs — see `applySnapshot` — and keeps its place itself.
    private var draggedItem: ItemID?
    /// The cell standing in for the row in the air — the one drawing nothing.
    /// Held on to by hand: a hidden cell is not one of `visibleCells`, so there
    /// is no finding it again by looking.
    private weak var gapCell: UICollectionViewCell?
    /// The spot the list is holding open for that row: the gap its category has
    /// parted to make. nil for the spots the insertion line marks instead — a
    /// category's first and last — where the row is listed nowhere and every
    /// category stands as if it had never held it.
    private var dragGap: (section: Int, index: Int)?
    /// Where the finger was when the list last changed shape under it. Taking
    /// the row out of the list, or putting it back, slides every row after it
    /// along by its height — which would otherwise hand the finger a different
    /// spot without it having moved at all (the insertion line jumping to the
    /// next category as a drag reaches the end of one). The spot it was aiming
    /// at stands until it has travelled half a row from there.
    private var gapAnchor: CGFloat?
    /// How tall the row in the air is, measured as it was lifted.
    private var draggedRowHeight: CGFloat = 44

    override func viewDidLoad() {
        super.viewDidLoad()

        let layout = UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self, sectionIndex < self.sections.count else { return nil }
            var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            config.headerMode = self.sections[sectionIndex].category.isEmpty ? .none : .supplementary
            config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.leadingSwipeActions(at: indexPath)
            }
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipeActions(at: indexPath)
            }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.topAnchor.constraint(equalTo: view.topAnchor),
            cv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        cv.delegate = self
        cv.dragDelegate = self
        cv.dropDelegate = self
        cv.dragInteractionEnabled = true
        // Swiping down over the search field's keyboard puts it away, as on every
        // other screen. This is the property SwiftUI's own
        // `.scrollDismissesKeyboard(.interactively)` sets — that modifier only
        // reaches SwiftUI's scroll views, not a collection view of our own.
        cv.keyboardDismissMode = .interactive
        // UIKit reports nothing when a lift is abandoned — the finger comes up
        // without ever moving, so no drag session begins and `dragSessionDidEnd`
        // never arrives. This recognizer is here only to notice that touch ending.
        // It changes nothing about how touches are handled (it cancels none of
        // them and runs alongside every other recognizer), and UIKit never lets it
        // recognize a touch that became a drag, so it stays silent for the whole
        // of a real one.
        let liftWatch = UILongPressGestureRecognizer(target: self,
                                                     action: #selector(liftEndedWithoutDrag(_:)))
        liftWatch.minimumPressDuration = 0
        liftWatch.cancelsTouchesInView = false
        liftWatch.delaysTouchesBegan = false
        liftWatch.delaysTouchesEnded = false
        liftWatch.delegate = self
        cv.addGestureRecognizer(liftWatch)
        // onRefresh is assigned before the view loads (apply() runs inside
        // makeUIViewController), so its presence is known here.
        if onRefresh != nil {
            let control = UIRefreshControl()
            control.addTarget(self, action: #selector(refreshPulled(_:)), for: .valueChanged)
            cv.refreshControl = control
        }
        // The system top edge effect is replaced by stableTopEdgeFade() in the
        // hosting SwiftUI view (see TopEdgeFade.swift for the why).
        cv.topEdgeEffect.isHidden = true
        collectionView = cv
        // Lets the navigation/tab bars apply their scrolled-under effects, like
        // they do for a SwiftUI List.
        setContentScrollView(cv, for: [.top, .bottom])

        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemID> {
            [weak self] cell, _, itemID in
            // Drop any leftover flash tint (see flash(at:)) if this cell is being
            // recycled for another row mid-highlight.
            if !cell.automaticallyUpdatesBackgroundConfiguration {
                cell.automaticallyUpdatesBackgroundConfiguration = true
                cell.setNeedsUpdateConfiguration()
            }
            let row = self?.rowsByID[itemID.id]
            if let row, let uploader = row.uploaderName, !uploader.isEmpty {
                // The uploader's name rides along in grey right after the
                // exercise name (Community tab). Separate labels, so a long
                // exercise name truncates with "…" while the uploader's name
                // always stays fully visible.
                cell.contentConfiguration = NameUploaderConfiguration(
                    name: row.exercise.localizedName, uploader: uploader,
                    onTapUploader: self?.onSelectUploader.map { open in
                        { open(uploader) }
                    }
                )
            } else {
                var content = UIListContentConfiguration.cell()
                // Long exercise names truncate with "…" instead of wrapping.
                content.textProperties.numberOfLines = 1
                content.textProperties.lineBreakMode = .byTruncatingTail
                content.text = row?.exercise.localizedName
                cell.contentConfiguration = content
            }
            var accessories: [UICellAccessory] = []
            if let isSelected = row?.isSelected {
                // The picker's selection mark, mimicking the system multi-select
                // circles: filled blue checkmark when selected, hollow grey when
                // not. Wrapped in a plain view because a bare UIImageView as the
                // accessory makes accessibility expose the whole row as an Image
                // (labelled "circle") instead of a cell — breaking VoiceOver and
                // UI tests alike.
                let mark = UIImageView(image: UIImage(
                    systemName: isSelected ? "checkmark.circle.fill" : "circle"
                ))
                mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
                mark.tintColor = isSelected ? .systemBlue : .tertiaryLabel
                mark.sizeToFit()
                let container = UIView(frame: mark.bounds)
                container.addSubview(mark)
                accessories.append(.customView(configuration: .init(
                    customView: container,
                    placement: .leading(),
                    reservedLayoutWidth: .actual,
                    maintainsFixedSize: true
                )))
            }
            if let pattern = row?.pattern, !pattern.isEmpty {
                accessories.append(.customView(configuration: .init(
                    customView: MIDIPatternView(notes: pattern),
                    placement: .trailing(),
                    reservedLayoutWidth: .actual,
                    maintainsFixedSize: true
                )))
            }
            cell.accessories = accessories
            // The row in the air is still listed while the drag lasts — as the
            // gap being held for it (see dragGap) — but none of it is drawn.
            cell.isHidden = itemID == self?.draggedItem
            if cell.isHidden { self?.gapCell = cell }
        }
        // The Home tab's cards get registrations of their own rather than more
        // branches of the one above: they share nothing with an exercise row but
        // the cell class, and keeping them apart keeps any of them from having
        // to undo another's leftovers.
        let calendarRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemID> {
            [weak self] cell, _, itemID in
            guard case .practiceCalendar(let days, let goalMinutes)
                    = self?.rowsByID[itemID.id]?.content
            else { return }
            // Handed the app's language by hand — the SwiftUI environment the
            // rest of the app sets it in stops at this collection view.
            let locale = (self?.language ?? LanguageManager.shared.language).locale
            cell.contentConfiguration = UIHostingConfiguration {
                PracticeCalendarView(days: days, goalMinutes: goalMinutes) { [weak self] selection in
                    self?.onCalendarSelect?(selection)
                }
                .environment(\.locale, locale)
                .explain(L("One square per day, oldest first. The more you practised, the fuller the colour, and a day that reached your daily practice time gets a tick. Tap a square to see that day."))
            }
            cell.accessories = []
        }
        let recommendationRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemID> {
            [weak self] cell, _, itemID in
            guard case .recommendation(let category, let skill) = self?.rowsByID[itemID.id]?.content
            else { return }
            let locale = (self?.language ?? LanguageManager.shared.language).locale
            cell.contentConfiguration = UIHostingConfiguration {
                RecommendationCard(category: category, skill: skill)
                    .environment(\.locale, locale)
                    .explain(L("Tap to sing everything the app suggests for you today, one exercise after another. The stars are your own level, which the suggestions are pitched at."))
            }
            cell.accessories = []
        }
        dataSource = UICollectionViewDiffableDataSource<String, ItemID>(collectionView: cv) {
            [weak self] collectionView, indexPath, itemID in
            switch self?.rowsByID[itemID.id]?.content {
            case .practiceCalendar:
                return collectionView.dequeueConfiguredReusableCell(
                    using: calendarRegistration, for: indexPath, item: itemID)
            case .recommendation:
                return collectionView.dequeueConfiguredReusableCell(
                    using: recommendationRegistration, for: indexPath, item: itemID)
            default:
                return collectionView.dequeueConfiguredReusableCell(
                    using: cellRegistration, for: indexPath, item: itemID)
            }
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<ExerciseSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            self?.configure(header: header, forSection: indexPath.section, animated: false)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }

        applySnapshot(animated: false, reconfiguring: [])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hideSearchBarIfNeeded()
    }

    /// SwiftUI's `.searchable` puts the field in the navigation bar's drawer and
    /// leaves it visible at the top of the list. Scrolling the list down by its
    /// height once — on the first layout that has both a search bar and content —
    /// gives the Messages-style behaviour instead: hidden by default, revealed by
    /// pulling down. Bails out (and retries next pass) until everything it needs
    /// exists, since SwiftUI installs the search controller after this view loads.
    private func hideSearchBarIfNeeded() {
        guard hidesSearchBarInitially, !hasHiddenSearchBar, let collectionView,
              collectionView.bounds.height > 0, collectionView.contentSize.height > 0
        else { return }
        // The search controller sits on the navigation item of the SwiftUI
        // hosting controller, one of this controller's ancestors.
        var searchBar: UISearchBar?
        var ancestor: UIViewController? = self
        while let vc = ancestor, searchBar == nil {
            searchBar = vc.navigationItem.searchController?.searchBar
            ancestor = vc.parent
        }
        guard let searchBar, searchBar.bounds.height > 0 else { return }
        hasHiddenSearchBar = true
        // Never past the end: with only a handful of exercises there's nothing to
        // scroll, and the field simply stays visible (as it would in Mail).
        let insets = collectionView.adjustedContentInset
        let maxOffset = max(-insets.top,
                            collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        collectionView.contentOffset.y = min(collectionView.contentOffset.y + searchBar.bounds.height,
                                             maxOffset)
    }

    // MARK: - Data

    @objc private func refreshPulled(_ control: UIRefreshControl) {
        Task { @MainActor in
            await onRefresh?()
            control.endRefreshing()
        }
    }

    func setSections(_ new: [ExerciseListSection], animated: Bool) {
        guard new != sections else { return }
        if collectionView?.hasActiveDrag == true || isPerformingDrop {
            pendingSections = new
            return
        }
        let oldByID = rowsByID
        sections = new
        rowsByID = Dictionary(
            new.flatMap { $0.items }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard dataSource != nil else { return } // applied in viewDidLoad
        // Rows whose exercise changed in place (e.g. renamed, MIDI edited) need
        // reconfiguring; diffable identity is the exercise id, so it won't notice
        // on its own. An exercise may sit in several sections, so reconfigure every
        // copy of it.
        let changedIDs = Set(rowsByID.keys.filter { oldByID[$0] != nil && oldByID[$0] != rowsByID[$0] })
        let reconfiguring = sections.flatMap { section in
            section.items.filter { changedIDs.contains($0.id) }
                .map { ItemID(section: section.category, id: $0.id) }
        }
        applySnapshot(animated: animated && view.window != nil, reconfiguring: reconfiguring)
    }

    private func applySnapshot(animated: Bool, reconfiguring: [ItemID]) {
        var snapshot = NSDiffableDataSourceSnapshot<String, ItemID>()
        for section in sections {
            snapshot.appendSections([section.category])
            snapshot.appendItems(section.items.map { ItemID(section: section.category, id: $0.id) },
                                 toSection: section.category)
        }
        // A row in the air is left out of the category it belongs to and put
        // back only where the list is holding a gap open for it. Taking it out
        // is what lets a category close ranks again when the drag moves on to a
        // spot marked by the insertion line instead.
        if let draggedItem {
            snapshot.deleteItems([draggedItem])
            if let gap = dragGap, gap.section < sections.count {
                let category = sections[gap.section].category
                let listed = snapshot.itemIdentifiers(inSection: category)
                if gap.index < listed.count {
                    snapshot.insertItems([draggedItem], beforeItem: listed[gap.index])
                } else {
                    snapshot.appendItems([draggedItem], toSection: category)
                }
            }
        }
        snapshot.reconfigureItems(reconfiguring.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: animated)
        updateVisibleHeaders(animated: animated)
        // Rows appended below the screen never come into view on their own, so
        // nothing else is going to say how few of them are left.
        checkLoadMore()
    }

    /// Looks at how many rows are left below the screen as things stand, and asks
    /// for the next page if that has run low.
    ///
    /// Whether more is wanted is a fact about where the list has been scrolled to,
    /// not an event: a row coming into view is only one of the things that can
    /// change it. So this is called from every SwiftUI update too — which is what
    /// picks the paging back up when the ask made while a page was already on the
    /// wire was turned down, and the user has stopped scrolling at the end of the
    /// list with no rows left to bring into view and ask again off the back of.
    func checkLoadMore() {
        guard let collectionView else { return }
        loadMoreIfNeeded(displaying: collectionView.indexPathsForVisibleItems.max())
    }

    /// Asks for the next page if the list is running out of rows below the ones
    /// on screen. `indexPath` is the lowest row in view — the one with the fewest
    /// rows under it — or nil when there are none to count from.
    private func loadMoreIfNeeded(displaying indexPath: IndexPath?) {
        guard let onLoadMore, let indexPath, indexPath.section < sections.count,
              indexPath.item < sections[indexPath.section].items.count
        else { return }
        var below = sections[indexPath.section].items.count - indexPath.item - 1
        for section in sections[(indexPath.section + 1)...] {
            below += section.items.count
        }
        if below < loadMoreThreshold { onLoadMore() }
    }

    /// Snapshots don't cover supplementaries, so collapse toggles and count
    /// changes have to be pushed to the visible headers by hand.
    private func updateVisibleHeaders(animated: Bool) {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            guard let header = collectionView.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath
            ) as? ExerciseSectionHeaderView else { continue }
            configure(header: header, forSection: indexPath.section, animated: animated)
        }
    }

    private func configure(header: ExerciseSectionHeaderView, forSection sectionIndex: Int, animated: Bool) {
        guard sectionIndex < sections.count else { return }
        let section = sections[sectionIndex]
        header.configure(name: section.displayName ?? ExerciseCategoryName.localized(section.category),
                         count: section.totalCount,
                         isCollapsed: section.isCollapsed, showsCount: section.showsCount,
                         showsChevron: section.showsChevron, animated: animated)
        header.onTap = { [weak self] in self?.onToggleCollapse?(section.category) }
        header.onLongPress = { [weak self] in self?.onHeaderLongPress?() }
        header.onAdd = section.showsAdd ? { [weak self] in self?.onAdd?(section.category) } : nil
        header.addHelp = section.showsAdd ? section.addHelp : nil
    }

    // MARK: - Highlight

    /// The last id `highlight(_:)` acted on, so the repeated calls SwiftUI makes
    /// on every update flash the row only once.
    private var highlightedID: UUID?

    /// Scroll `id` into view and flash it, to point out a row the user can't be
    /// expected to find on their own (a just-created exercise, which lands at the
    /// bottom of its category).
    func highlight(_ id: UUID) {
        guard id != highlightedID else { return }
        highlightedID = id
        // The list is still behind the screen being popped, and the snapshot for
        // the exercise's final category may not have been applied yet: let both
        // land first, so the scroll is something the user actually sees happen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let location = self.location(of: id) else { return }
            let indexPath = IndexPath(item: location.item, section: location.section)
            self.collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.flash(at: indexPath)
            }
        }
    }

    /// Tint the row in the accent colour and fade back out. Done through the
    /// cell's background configuration rather than an overlay view so the tint
    /// picks up the inset-grouped rounded corners on a category's first/last row.
    private func flash(at indexPath: IndexPath) {
        guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
        else { return }
        let base = cell.defaultBackgroundConfiguration()
        var tinted = base
        tinted.backgroundColor = UIColor.tintColor.withAlphaComponent(0.3)
        // The cell would otherwise recompute its background from its state at any
        // moment and drop the tint mid-fade.
        cell.automaticallyUpdatesBackgroundConfiguration = false
        UIView.animate(withDuration: 0.25) {
            cell.backgroundConfiguration = tinted
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            UIView.animate(withDuration: 0.4) {
                cell.backgroundConfiguration = base
            } completion: { _ in
                // Hand the background back to the cell, so selection and highlight
                // states drive it again.
                cell.automaticallyUpdatesBackgroundConfiguration = true
                cell.setNeedsUpdateConfiguration()
            }
        }
    }

    private func location(of id: UUID) -> (section: Int, item: Int)? {
        for (sectionIndex, section) in sections.enumerated() {
            if let itemIndex = section.items.firstIndex(where: { $0.id == id }) {
                return (sectionIndex, itemIndex)
            }
        }
        return nil
    }

    /// Where a specific copy of a row sits — the one in its own section, rather
    /// than whichever section happens to list that exercise first.
    private func location(of item: ItemID) -> (section: Int, item: Int)? {
        guard let sectionIndex = sections.firstIndex(where: { $0.category == item.section }),
              let itemIndex = sections[sectionIndex].items.firstIndex(where: { $0.id == item.id })
        else { return nil }
        return (sectionIndex, itemIndex)
    }

    /// A section's header, when it's on screen and the section has one — the
    /// uncategorized group is drawn without.
    private func header(ofSection sectionIndex: Int) -> ExerciseSectionHeaderView? {
        guard sectionIndex >= 0, sectionIndex < sections.count else { return nil }
        return collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: sectionIndex)
        ) as? ExerciseSectionHeaderView
    }

    /// The line drawn where a row let go between two categories would land. The
    /// collection view opens no gap of its own there (see `boundaryTarget`), so
    /// without this the last spot of a category is aimed at blind.
    private lazy var insertionLine: UIView = {
        let line = UIView()
        line.backgroundColor = .tintColor
        line.layer.cornerRadius = 1.5
        line.isUserInteractionEnabled = false
        line.isHidden = true
        return line
    }()

    /// Draw the line where `target` would put the row, or take it away — for a
    /// drop into a gap the collection view is already showing, the gap says it.
    private func updateInsertionLine(for target: DropTarget?) {
        // A row gives the line the width of the group boxes; with every category
        // collapsed there are none, so a header stands in.
        let anchor: UIView? = target.map { collectionView.visibleCells.first ?? header(ofSection: $0.section) } ?? nil
        guard let target, target.drawsLine,
              let reference = anchor.map({ $0.convert($0.bounds, to: collectionView) }),
              let y = insertionLineY(for: target)
        else {
            insertionLine.isHidden = true
            return
        }
        if insertionLine.superview !== collectionView { collectionView.addSubview(insertionLine) }
        collectionView.bringSubviewToFront(insertionLine)
        insertionLine.frame = CGRect(x: reference.minX, y: y - 1.5, width: reference.width, height: 3)
        insertionLine.isHidden = false
    }

    /// Where that line sits. Every spot it marks is a category's own edge — its
    /// first or its last, either side of a line between two categories — so it
    /// goes over the top of the category's first cell or under the bottom of its
    /// last, or under its header when it has no cells on show. Cells, not rows:
    /// the gap held for the row in the air is one of them, and where the drop
    /// would land on top of that gap the line belongs on its far side.
    private func insertionLineY(for target: DropTarget) -> CGFloat? {
        let cells = collectionView.numberOfItems(inSection: target.section)
        let atTop = (target.item ?? cells) <= 0
        if !sections[target.section].isCollapsed, cells > 0,
           let frame = cellFrame(IndexPath(item: atTop ? 0 : cells - 1, section: target.section)) {
            return atTop ? frame.minY : frame.maxY
        }
        return header(ofSection: target.section)
            .map { $0.convert($0.bounds, to: collectionView).maxY }
    }

    /// Where a cell sits in the list. Read off the layout rather than the cell:
    /// the gap held for the row in the air draws nothing, and a hidden cell is
    /// not one the collection view will hand back. The layout also gives the
    /// place a cell is on its way to, which is the one worth answering with
    /// while the rows are still easing into a gap that just moved.
    private func cellFrame(_ indexPath: IndexPath) -> CGRect? {
        collectionView.collectionViewLayout.layoutAttributesForItem(at: indexPath)?.frame
    }

    /// How many of a category's rows the finger is past, which is the spot the
    /// dragged row would take. The gap being held open doesn't count itself, so
    /// the answer is an index into the category without the row in the air —
    /// exactly what the drop needs.
    ///
    /// The spot already being shown keeps a little of the finger's travel to
    /// itself (`spotStickiness`) so a hand that isn't quite still can't flip a
    /// category back and forth across a row's midpoint.
    private func insertionIndex(inSection section: Int, at point: CGPoint) -> Int {
        let rows = displayedRows(inSection: section)
        func rowsPassed(by y: CGFloat) -> Int {
            rows.filter { item in
                guard let frame = cellFrame(IndexPath(item: item, section: section))
                else { return false }
                return frame.midY < y
            }.count
        }
        let index = rowsPassed(by: point.y)
        guard let held = liveDropTarget.flatMap({ $0.section == section ? $0.item : nil }),
              held != index
        else { return index }
        let stepped = point.y + (index > held ? -spotStickiness : spotStickiness)
        return rowsPassed(by: stepped) == held ? held : index
    }

    /// How far past a row's middle the finger has to carry on before the list
    /// gives up the spot it is already showing.
    private let spotStickiness: CGFloat = 8

    /// The rows a category is showing right now, as item indexes. The gap being
    /// held for the row in the air is one of the category's cells but it isn't a
    /// row — it is the space that row would take — so it is left out.
    private func displayedRows(inSection section: Int) -> [Int] {
        let count = collectionView.numberOfItems(inSection: section)
        let gap = dragGap?.section == section ? dragGap?.index : nil
        return (0..<count).filter { $0 != gap }
    }

    /// Whether a spot is the first or the last of its category — the two with no
    /// row on one side of them. The list opens no gap for those: the category's
    /// own edge is already there to aim at, and shoving its rows aside to spell
    /// out a spot beyond them reads as a spot further in. The insertion line
    /// marks them instead, and every row stays where it belongs.
    private func isEdgeSpot(_ index: Int?, inSection section: Int) -> Bool {
        guard let index else { return true }
        return index <= 0 || index >= displayedRows(inSection: section).count
    }

    /// The section whose header `point` is inside.
    private func headerSection(at point: CGPoint) -> Int? {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            guard let header = header(ofSection: indexPath.section) else { continue }
            if header.convert(header.bounds, to: collectionView).contains(point) {
                return indexPath.section
            }
        }
        return nil
    }

    /// The nearest section whose header starts at or below `point` — the category
    /// the touch is above, when it's in the gap between two groups.
    private func sectionBelow(_ point: CGPoint) -> Int? {
        var nearest: (section: Int, minY: CGFloat)?
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            guard let header = header(ofSection: indexPath.section) else { continue }
            let minY = header.convert(header.bounds, to: collectionView).minY
            guard minY >= point.y else { continue }
            if nearest == nil || minY < nearest!.minY { nearest = (indexPath.section, minY) }
        }
        return nearest?.section
    }

    private func leadingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard onSettings != nil,
              let id = dataSource.itemIdentifier(for: indexPath)?.id,
              let row = rowsByID[id], row.content == .exercise else { return nil }
        let action = UIContextualAction(style: .normal, title: row.swipeActionTitle) { [weak self] _, _, done in
            self?.onSettings?(id)
            done(true)
        }
        action.image = UIImage(systemName: row.swipeActionImage)
        action.backgroundColor = .systemBlue
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    private func trailingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard onDelete != nil,
              let id = dataSource.itemIdentifier(for: indexPath)?.id,
              rowsByID[id]?.showsDelete == true else { return nil }
        let action = UIContextualAction(style: .destructive, title: L("Delete")) { [weak self] _, _, done in
            self?.onDelete?(id)
            // false, so the row isn't removed here: a confirmation alert follows,
            // and the row only leaves once the store update flows back in.
            done(false)
        }
        action.image = UIImage(systemName: "trash")
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }
}

// MARK: - Selection

extension ExerciseListController: UICollectionViewDelegate {
    /// The Home tab's calendar has nothing to open, so it never highlights under
    /// the finger and never reports a tap — the taps on it belong to the view it
    /// draws. Every other row, cards included, opens something.
    func collectionView(_ collectionView: UICollectionView,
                        shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              let row = rowsByID[item.id] else { return true }
        return row.content.isSelectable
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelect?(item.id, item.section)
    }

    /// Asks for the next page once the rows left below the bottom of the screen
    /// run low (Community tab). Counted from each row as it comes into view, so
    /// the lowest one on screen — the one with the fewest rows under it — is what
    /// decides; a list that doesn't even fill the screen asks straight away.
    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        loadMoreIfNeeded(displaying: indexPath)
    }

    /// The calendar's bubble is drawn over the list, not in it, so it doesn't
    /// travel with the square it points at — scrolling puts it away instead.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onCalendarSelect?(nil)
    }
}

// MARK: - Drag & drop

extension ExerciseListController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard onMove != nil,
              indexPath.section < sections.count, sections[indexPath.section].allowsReorder,
              let itemID = dataSource.itemIdentifier(for: indexPath) else { return [] }
        liveDropTarget = nil
        let item = UIDragItem(itemProvider: NSItemProvider(object: itemID.id.uuidString as NSString))
        // The whole ItemID, not just the exercise's: the same exercise can be
        // listed in two sections at once (Home), so only the pair says which of
        // its copies was picked up.
        item.localObject = itemID
        // The lift — the row swelling under the finger — starts here. The drag
        // session itself doesn't begin until the finger moves, a second or more
        // later, which is far too late to say that the list is being rearranged.
        onDragChange?(true)
        return [item]
    }

    /// The finger has started moving the row it lifted. Says so again in case
    /// anything (a second finger touching down mid-lift) cleared it in between,
    /// and takes the row into the list's own hands for the rest of the drag.
    func collectionView(_ collectionView: UICollectionView, dragSessionWillBegin session: UIDragSession) {
        onDragChange?(true)
        beginDrag(session.items.first?.localObject as? ItemID)
    }

    /// The list stops listing the row where it belongs and starts keeping its
    /// place itself: its cell stays on as the gap being held for it, drawing
    /// nothing. Which is what lets the gap be taken away again — UIKit opens one
    /// of its own a spot out from where the drop would land, and won't close or
    /// move it back once it has.
    private func beginDrag(_ item: ItemID?) {
        guard let item, let home = location(of: item) else { return }
        draggedItem = item
        // Held where it was lifted from until the first drop update says
        // otherwise, so the list doesn't stir before the drag is under way.
        dragGap = (home.section, home.item)
        gapAnchor = nil
        let indexPath = IndexPath(item: home.item, section: home.section)
        draggedRowHeight = cellFrame(indexPath)?.height ?? draggedRowHeight
        gapCell = collectionView.cellForItem(at: indexPath)
        gapCell?.isHidden = true
    }

    /// The drag ended without a drop taking the row: it goes back where it was
    /// lifted from. A drop hands it back itself (see performDropWith), so this
    /// finds nothing left to do after one.
    private func endDrag() {
        guard draggedItem != nil else { return }
        draggedItem = nil
        dragGap = nil
        gapAnchor = nil
        showEveryRow()
        applySnapshot(animated: true, reconfiguring: [])
    }

    /// Undoes the hiding above — every row is a row again.
    private func showEveryRow() {
        gapCell?.isHidden = false
        gapCell = nil
    }

    /// The drag is over — dropped, or sprung back after a cancel.
    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        updateInsertionLine(for: nil)
        onDragChange?(false)
        // The safety net for a drag that ended without a drop session to end
        // with. Deferred so it can never come before the drop itself.
        DispatchQueue.main.async { [weak self] in self?.endDrag() }
    }

    /// A touch that never became a drag has ended: either a lift the user let go
    /// of without moving — which gets no session, and so no `dragSessionDidEnd` —
    /// or an ordinary tap or scroll, for which saying "not dragging" is a no-op.
    @objc private func liftEndedWithoutDrag(_ recognizer: UIGestureRecognizer) {
        switch recognizer.state {
        case .ended, .cancelled, .failed:
            guard collectionView?.hasActiveDrag != true else { return }
            onDragChange?(false)
        default:
            break
        }
    }

    /// Whether the section at `sectionIndex` takes the row `dragged`: the section
    /// has to be reorderable at all, and — when moves are kept in their section —
    /// has to be the one the row was lifted from.
    private func canDrop(_ dragged: ItemID?, into sectionIndex: Int) -> Bool {
        guard sectionIndex >= 0, sectionIndex < sections.count,
              sections[sectionIndex].allowsReorder else { return false }
        guard movesStayInSection else { return true }
        return sections[sectionIndex].category == dragged?.section
    }

    /// Where a drop lands: the section, and the index within it — nil appending,
    /// which is also what a collapsed category gets, its order being out of sight.
    private struct DropTarget {
        var section: Int
        var item: Int?
        /// true when the list holds no insertion gap open for this spot — it is
        /// on the line between two categories, or at the first or last spot of a
        /// category — and `insertionLine` stands in for one.
        var drawsLine: Bool
    }

    /// Where a drop at `point` would land.
    private func dropTarget(at point: CGPoint, dragged: ItemID?) -> DropTarget? {
        // A collapsed category is only ever reachable through its header.
        if let hit = headerSection(at: point), sections[hit].isCollapsed, canDrop(dragged, into: hit) {
            return DropTarget(section: hit, item: nil, drawsLine: true)
        }
        // Over a row: which category it belongs to is all that is taken from it.
        // The spot within that category is how many of its rows the finger is
        // past, in the list as it stands.
        if let over = collectionView.indexPathForItem(at: point), canDrop(dragged, into: over.section) {
            let item = insertionIndex(inSection: over.section, at: point)
            return DropTarget(section: over.section, item: item,
                              drawsLine: isEdgeSpot(item, inSection: over.section))
        }
        return boundaryTarget(at: point, dragged: dragged)
    }

    /// A drop let go on the line between two categories, where the collection
    /// view has no insertion gap of its own — it never offers one past the last
    /// row of a category, and none at all over a header or the space around it.
    /// The line is read off the screen: the category name marks the middle of it,
    /// so letting go above the name adds the row to the end of the category above
    /// and below the name puts it at the top of the one below. `insertionLine`
    /// draws exactly that while the finger is there, so the two are never a
    /// guess.
    ///
    /// A collapsed category is the exception: its header is the only part of it
    /// on screen, so the whole header files the row into it (wherever — its order
    /// is out of sight).
    private func boundaryTarget(at point: CGPoint, dragged: ItemID?) -> DropTarget? {
        // The header the touch is on is the line's lower side; failing that, the
        // next header down. Past the last category, the line is the list's end.
        let below = headerSection(at: point) ?? sectionBelow(point) ?? sections.count
        let above = below - 1
        let intoBelow = below < sections.count
            ? DropTarget(section: below, item: 0, drawsLine: true) : nil
        let intoAbove = above >= 0
            ? DropTarget(section: above, item: nil, drawsLine: true) : nil
        let onLowerSide = header(ofSection: below).map {
            point.y >= $0.convert($0.bounds, to: collectionView).midY
        } ?? false
        let preferred = onLowerSide ? [intoBelow, intoAbove] : [intoAbove, intoBelow]
        // Whichever side it is, that category still has to take drops at all (and,
        // on the Home tab, be the one the row was lifted from).
        return preferred.compactMap { $0 }.first { canDrop(dragged, into: $0.section) }
    }

    func collectionView(_ collectionView: UICollectionView,
                        dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        true
    }

    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        let point = session.location(in: collectionView)
        guard session.localDragSession != nil,
              var target = dropTarget(at: point, dragged: draggedItem)
        else {
            liveDropTarget = nil
            setDragGap(nil, at: point.y)
            updateInsertionLine(for: nil)
            return UICollectionViewDropProposal(operation: .cancel)
        }
        // A spot the list has just changed shape for keeps the finger's aim
        // (see gapAnchor).
        if let anchor = gapAnchor, let held = liveDropTarget,
           abs(point.y - anchor) < draggedRowHeight / 2 {
            target = held
        } else {
            gapAnchor = nil
        }
        liveDropTarget = target
        // A spot with rows on both sides is shown by parting them for it. The
        // rest — a category's first and last spot, and the line between two
        // categories — are marked by the insertion line alone, and the row is
        // listed nowhere at all: every category it isn't going into closes
        // ranks, the one it came from included.
        setDragGap(target.drawsLine ? nil : target.item.map { (target.section, $0) }, at: point.y)
        updateInsertionLine(for: target)
        // The list holds that gap itself, so UIKit is asked to leave the
        // arrangement alone.
        return UICollectionViewDropProposal(operation: .move, intent: .unspecified)
    }

    /// Hold the gap open at `gap`, or take it away — the rows animate into
    /// whichever shape that leaves, and the finger's aim is pinned to `y` while
    /// they do (see gapAnchor).
    private func setDragGap(_ gap: (section: Int, index: Int)?, at y: CGFloat) {
        guard draggedItem != nil,
              dragGap?.section != gap?.section || dragGap?.index != gap?.index
        else { return }
        dragGap = gap
        gapAnchor = y
        applySnapshot(animated: true, reconfiguring: [])
    }

    func collectionView(_ collectionView: UICollectionView,
                        performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let dropItem = coordinator.items.first,
              let dragged = dropItem.dragItem.localObject as? ItemID,
              let source = location(of: dragged),
              let target = liveDropTarget
                  ?? dropTarget(at: coordinator.session.location(in: collectionView), dragged: dragged)
        else { return }
        let id = dragged.id
        let destinationSection = target.section
        let destinationItem = target.item
        updateInsertionLine(for: nil)
        var new = sections
        let moved = new[source.section].items.remove(at: source.item)
        new[source.section].totalCount -= 1

        let category = new[destinationSection].category
        var beforeID: UUID?
        var finalIndexPath: IndexPath?
        if new[destinationSection].isCollapsed {
            // Into a collapsed category: the exercise joins it but stays hidden.
            new[destinationSection].totalCount += 1
        } else if let destinationItem {
            let insertIndex = min(destinationItem, new[destinationSection].items.count)
            new[destinationSection].items.insert(moved, at: insertIndex)
            new[destinationSection].totalCount += 1
            if insertIndex + 1 < new[destinationSection].items.count {
                beforeID = new[destinationSection].items[insertIndex + 1].id
            }
            finalIndexPath = IndexPath(item: insertIndex, section: destinationSection)
        } else {
            // Let go past the end of a category (or on the line under it).
            new[destinationSection].items.append(moved)
            new[destinationSection].totalCount += 1
            finalIndexPath = IndexPath(item: new[destinationSection].items.count - 1,
                                       section: destinationSection)
        }

        // Named categories stay visible when emptied (showing "(0)"), but the
        // unlabelled uncategorized group disappears, like in the SwiftUI view.
        if new[source.section].totalCount == 0, new[source.section].category.isEmpty {
            new.remove(at: source.section)
            if var indexPath = finalIndexPath, indexPath.section > source.section {
                indexPath.section -= 1
                finalIndexPath = indexPath
            }
        }

        isPerformingDrop = true
        sections = new
        if destinationSection != source.section {
            var updated = moved
            updated.exercise.category = category
            rowsByID[id] = updated
        }
        // The row is the list's to keep again, so the snapshot below lists it
        // where it was let go rather than in the gap that was held for it — and
        // it is drawn again from this moment on. Waiting for the drop animation
        // to finish before letting it back in is what UIKit does with its own
        // gap, but the animation only reports itself done well after the lifted
        // copy has landed, leaving a hole where the row should already be.
        draggedItem = nil
        dragGap = nil
        gapAnchor = nil
        showEveryRow()
        // Animated, and timed with the drop. Let go on a spot the rows had
        // already parted for, this asks for the arrangement that is on screen
        // and nothing moves at all; let go on a spot the line marked, this is
        // what parts them, easing open under the row as it lands rather than
        // jumping open beneath it.
        applySnapshot(animated: true, reconfiguring: [])
        if let finalIndexPath {
            coordinator.drop(dropItem.dragItem, toItemAt: finalIndexPath)
        } else if let headerIndex = sections.firstIndex(where: { $0.category == category }),
                  let headerView = collectionView.supplementaryView(
                      forElementKind: UICollectionView.elementKindSectionHeader,
                      at: IndexPath(item: 0, section: headerIndex)
                  ) {
            let target = UIDragPreviewTarget(
                container: headerView,
                center: CGPoint(x: headerView.bounds.midX, y: headerView.bounds.midY)
            )
            coordinator.drop(dropItem.dragItem, to: target)
        }
        isPerformingDrop = false

        // Tell the store after the drop's own layout pass so the SwiftUI update
        // (which round-trips back into setSections) can't fight the animation.
        DispatchQueue.main.async { [weak self] in
            self?.onMove?(id, category, beforeID)
        }
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) {
        liveDropTarget = nil
        endDrag()
        updateInsertionLine(for: nil)
        if let pending = pendingSections {
            pendingSections = nil
            setSections(pending, animated: true)
        }
    }
}

extension ExerciseListController: UIGestureRecognizerDelegate {
    /// The lift watcher only observes; it must never make another recognizer —
    /// the scroll, the drag lift, a swipe action — wait on it or lose to it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Name + uploader cell content

/// Cell content for Community rows: exercise name with the uploader's name in
/// grey right after it. Two labels instead of one attributed string, so a long
/// exercise name truncates with "…" while the uploader stays fully visible.
private struct NameUploaderConfiguration: UIContentConfiguration {
    var name: String
    var uploader: String
    /// Tapping the uploader's name opens their profile; nil leaves it inert.
    var onTapUploader: (() -> Void)?

    func makeContentView() -> UIView & UIContentView {
        NameUploaderContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> NameUploaderConfiguration { self }
}

private final class NameUploaderContentView: UIView, UIContentView {
    private let nameLabel = UILabel()
    private let uploaderLabel = UILabel()

    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    func supports(_ configuration: UIContentConfiguration) -> Bool {
        configuration is NameUploaderConfiguration
    }

    init(configuration: NameUploaderConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        // Match the plain rows, which use UIListContentConfiguration.cell().
        let defaults = UIListContentConfiguration.cell()
        nameLabel.font = defaults.textProperties.font
        nameLabel.textColor = defaults.textProperties.color
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        uploaderLabel.font = .preferredFont(forTextStyle: .subheadline)
        uploaderLabel.textColor = .secondaryLabel
        uploaderLabel.adjustsFontForContentSizeCategory = true
        uploaderLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The recognizer cancels the touch for the cell, so tapping the name
        // opens the uploader's profile instead of selecting the row.
        uploaderLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(uploaderTapped))
        )

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        uploaderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        addSubview(uploaderLabel)
        preservesSuperviewLayoutMargins = true
        let margins = defaults.directionalLayoutMargins
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margins.bottom),
            uploaderLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            uploaderLabel.trailingAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.trailingAnchor),
            uploaderLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func apply() {
        guard let config = configuration as? NameUploaderConfiguration else { return }
        nameLabel.text = config.name
        uploaderLabel.text = config.uploader
        uploaderLabel.isUserInteractionEnabled = config.onTapUploader != nil
    }

    @objc private func uploaderTapped() {
        (configuration as? NameUploaderConfiguration)?.onTapUploader?()
    }
}

// MARK: - Pattern thumbnail

/// A miniature piano-roll of an exercise's MIDI pattern, shown on the trailing
/// edge of its row. Notes are drawn in the colour chosen under Visuals > Menus.
final class MIDIPatternView: UIView {
    /// Settable, since the SwiftUI wrapper below reuses one view across rows —
    /// the list itself hands over a fresh view per cell.
    var notes: [MIDINote] {
        didSet { setNeedsDisplay() }
    }

    init(notes: [MIDINote]) {
        self.notes = notes
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        isOpaque = false
        backgroundColor = .clear
        // Repaint when the colour is changed in Settings, so returning to the list
        // shows the new one without the cells having to be reconfigured.
        NotificationCenter.default.addObserver(
            self, selector: #selector(setNeedsDisplayNow),
            name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc private func setNeedsDisplayNow() { setNeedsDisplay() }

    /// The pattern colour as stored by the Menus visual settings.
    private var patternColor: UIColor {
        let hex = UserDefaults.standard.string(forKey: MenuVisualKeys.exercisePreviewColor)
            ?? MenuVisualDefaults.exercisePreviewColor
        return UIColor(Color(hex: hex))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let size = CGSize(width: 64, height: 26)
    override var intrinsicContentSize: CGSize { Self.size }

    override func draw(_ rect: CGRect) {
        guard let first = notes.first else { return }
        let content = bounds

        var minBeat = first.beat
        var maxEnd = first.beat + first.length
        var minPitch = first.pitch
        var maxPitch = first.pitch
        for note in notes.dropFirst() {
            minBeat = min(minBeat, note.beat)
            maxEnd = max(maxEnd, note.beat + note.length)
            minPitch = min(minPitch, note.pitch)
            maxPitch = max(maxPitch, note.pitch)
        }
        let beatSpan = max(maxEnd - minBeat, 0.001)
        let pitchSpan = maxPitch - minPitch

        // Thin bars, so patterns spanning many rows still read at this size.
        let noteH = min(max(content.height / CGFloat(pitchSpan + 1), 2), 4)
        patternColor.setFill()
        for note in notes {
            let x = (note.beat - minBeat) / beatSpan * content.width
            let w = max(note.length / beatSpan * content.width - 1, 2)
            let y = pitchSpan == 0
                ? (content.height - noteH) / 2
                : CGFloat(maxPitch - note.pitch) / CGFloat(pitchSpan) * (content.height - noteH)
            UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: noteH),
                         cornerRadius: 1).fill()
        }
    }
}

/// The same thumbnail, for the SwiftUI lists that show exercise rows of their
/// own — the routine and exercise-queue screens, where it sits just left of the
/// drag handle. Wrapping the list's own view rather than drawing the pattern a
/// second time in SwiftUI is what keeps the two identical.
struct MIDIPatternThumbnail: UIViewRepresentable {
    let notes: [MIDINote]

    func makeUIView(context: Context) -> MIDIPatternView {
        MIDIPatternView(notes: notes)
    }

    func updateUIView(_ view: MIDIPatternView, context: Context) {
        view.notes = notes
    }

    /// Its fixed size, whatever SwiftUI proposes — the same size the list's rows
    /// reserve for it.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: MIDIPatternView,
                      context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
}

// MARK: - Section header

/// Replica of the SwiftUI section header: category name, exercise count while
/// collapsed, and a chevron that points right (collapsed) or down (expanded).
/// Tap toggles collapse; a long press enters category-reorder mode. Sections
/// with an add handler show a + button right after the name (Routines on Home).
final class ExerciseSectionHeaderView: UICollectionReusableView {
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onAdd: (() -> Void)? {
        didSet { addButton.isHidden = onAdd == nil }
    }
    /// Press-and-hold help for the + button, shown in the same bubble the
    /// SwiftUI screens use (see SettingHelp). nil leaves the hold doing nothing:
    /// the header's own hold is excluded from controls, so it can't stand in.
    var addHelp: String?

    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private let addButton = UIButton(type: .system)
    private let chevron = UIImageView()
    private var isCollapsed = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Take the exact type the system uses for grouped-list headers so the
        // header is indistinguishable from the SwiftUI Section header it replaces.
        let headerDefaults = UIListContentConfiguration.groupedHeader()
        nameLabel.font = headerDefaults.textProperties.font
        nameLabel.textColor = headerDefaults.textProperties.color
        nameLabel.adjustsFontForContentSizeCategory = true
        countLabel.font = headerDefaults.textProperties.font
        countLabel.textColor = .tertiaryLabel
        countLabel.adjustsFontForContentSizeCategory = true
        chevron.image = UIImage(systemName: "chevron.right")
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: headerDefaults.textProperties.font)
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        // A grey circle behind the + marks it as tappable, the same way the like
        // button on the exercise intro sits on a `.fill.tertiary` capsule.
        var addConfig = UIButton.Configuration.plain()
        addConfig.image = UIImage(systemName: "plus")
        addConfig.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(font: headerDefaults.textProperties.font)
        addConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        addConfig.background.backgroundColor = .tertiarySystemFill
        addConfig.cornerStyle = .capsule
        addButton.configuration = addConfig
        // The plus glyph is narrower than it is tall, so match the width to the
        // height to keep the capsule a circle rather than a stubby pill.
        addButton.widthAnchor.constraint(equalTo: addButton.heightAnchor).isActive = true
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        addButton.accessibilityLabel = L("Add")
        addButton.isHidden = true
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        // The header's own long press is kept off the controls inside it (see the
        // delegate below), so the + button carries its own.
        let addHold = UILongPressGestureRecognizer(target: self,
                                                   action: #selector(addHeldDown(_:)))
        addHold.minimumPressDuration = 0.4
        addButton.addGestureRecognizer(addHold)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [nameLabel, addButton, countLabel, spacer, chevron])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.5
        // The delegate keeps a slow press on the + button from also triggering
        // reorder mode (taps on controls already take precedence on their own).
        longPress.delegate = self
        addGestureRecognizer(longPress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, count: Int, isCollapsed: Bool, showsCount: Bool,
                   showsChevron: Bool, animated: Bool) {
        nameLabel.text = name
        countLabel.text = "(\(count))"
        countLabel.isHidden = !showsCount || (!isCollapsed && count > 0)
        chevron.isHidden = !showsChevron
        self.isCollapsed = isCollapsed
        let transform = isCollapsed ? .identity : CGAffineTransform(rotationAngle: .pi / 2)
        if animated {
            UIView.animate(withDuration: 0.3) { self.chevron.transform = transform }
        } else {
            chevron.transform = transform
        }
    }

    @objc private func tapped() { onTap?() }

    @objc private func addTapped() { onAdd?() }

    @objc private func addHeldDown(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let addHelp else { return }
        SettingHelpBubble.present(addHelp, from: addButton)
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onLongPress?()
    }
}

extension ExerciseSectionHeaderView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
}
