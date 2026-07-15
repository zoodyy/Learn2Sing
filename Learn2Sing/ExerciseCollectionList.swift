import SwiftUI
import UIKit

/// One row of the exercise list: the exercise plus its MIDI pattern (a single
/// repetition — the stored notes, before any repeat/transpose playback settings),
/// drawn as a thumbnail on the row's trailing edge.
struct ExerciseListRow: Equatable {
    var exercise: Exercise
    var pattern: [MIDINote]
    /// Shown in grey between the name and the pattern thumbnail (Community tab
    /// only — nil hides it).
    var uploaderName: String? = nil
    /// nil hides the selection mark; true/false draws a filled/empty circle on
    /// the row's leading edge (the routine exercise picker).
    var isSelected: Bool? = nil
    /// Title and symbol of the leading "Settings" swipe action, so rows that
    /// aren't exercises (routines on the Home tab) can label it differently.
    var swipeActionTitle = "Settings"
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
}

/// The normal-mode exercise list. This is intentionally NOT a SwiftUI List: a
/// List can never commit an internal drag onto another row or section (row-level
/// drop modifiers aren't consulted for List-internal drags, `.onDrag` crashes on
/// multi-section lists, and per-section `.onMove` can't cross sections). It is a
/// UICollectionView in the same insetGrouped list style SwiftUI's List is backed
/// by — same appearance — with drag & drop driven directly through UIKit's
/// drag/drop delegates: an exercise can be dragged to reorder within its category
/// or dropped into another one (including onto a collapsed category's header).
struct ExerciseCollectionList: UIViewControllerRepresentable {
    var sections: [ExerciseListSection]
    var onSelect: (UUID) -> Void
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
    /// (exercise, newCategory, idOfExerciseItNowPrecedes — nil appends).
    /// nil disables drag & drop entirely (Community tab).
    var onMove: ((UUID, String, UUID?) -> Void)? = nil

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
        controller.onMove = onMove
        controller.setSections(sections, animated: true)
    }
}

final class ExerciseListController: UIViewController {
    var onSelect: ((UUID) -> Void)?
    var onSelectUploader: ((String) -> Void)?
    var onRefresh: (() async -> Void)?
    var onSettings: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onToggleCollapse: ((String) -> Void)?
    var onHeaderLongPress: (() -> Void)?
    var onAdd: ((String) -> Void)?
    var onMove: ((UUID, String, UUID?) -> Void)?

    private var sections: [ExerciseListSection] = []
    private var rowsByID: [UUID: ExerciseListRow] = [:]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, UUID>!
    /// Sections handed over while a drag was in flight; deferred because mutating
    /// the layout mid-drag cancels the lift (and crashes SwiftUI's equivalent).
    private var pendingSections: [ExerciseListSection]?
    private var isPerformingDrop = false

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

        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> {
            [weak self] cell, _, id in
            let row = self?.rowsByID[id]
            if let row, let uploader = row.uploaderName, !uploader.isEmpty {
                // The uploader's name rides along in grey right after the
                // exercise name (Community tab). Separate labels, so a long
                // exercise name truncates with "…" while the uploader's name
                // always stays fully visible.
                cell.contentConfiguration = NameUploaderConfiguration(
                    name: row.exercise.name, uploader: uploader,
                    onTapUploader: self?.onSelectUploader.map { open in
                        { open(uploader) }
                    }
                )
            } else {
                var content = UIListContentConfiguration.cell()
                // Long exercise names truncate with "…" instead of wrapping.
                content.textProperties.numberOfLines = 1
                content.textProperties.lineBreakMode = .byTruncatingTail
                content.text = row?.exercise.name
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
        }
        dataSource = UICollectionViewDiffableDataSource<String, UUID>(collectionView: cv) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
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
        // reconfiguring; diffable identity is the UUID, so it won't notice on its own.
        let changed = rowsByID.keys.filter { oldByID[$0] != nil && oldByID[$0] != rowsByID[$0] }
        applySnapshot(animated: animated && view.window != nil, reconfiguring: Array(changed))
    }

    private func applySnapshot(animated: Bool, reconfiguring: [UUID]) {
        var snapshot = NSDiffableDataSourceSnapshot<String, UUID>()
        for section in sections {
            snapshot.appendSections([section.category])
            snapshot.appendItems(section.items.map(\.id), toSection: section.category)
        }
        snapshot.reconfigureItems(reconfiguring)
        dataSource.apply(snapshot, animatingDifferences: animated)
        updateVisibleHeaders(animated: animated)
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
        header.configure(name: section.category, count: section.totalCount,
                         isCollapsed: section.isCollapsed, showsCount: section.showsCount,
                         animated: animated)
        header.onTap = { [weak self] in self?.onToggleCollapse?(section.category) }
        header.onLongPress = { [weak self] in self?.onHeaderLongPress?() }
        header.onAdd = section.showsAdd ? { [weak self] in self?.onAdd?(section.category) } : nil
    }

    private func location(of id: UUID) -> (section: Int, item: Int)? {
        for (sectionIndex, section) in sections.enumerated() {
            if let itemIndex = section.items.firstIndex(where: { $0.id == id }) {
                return (sectionIndex, itemIndex)
            }
        }
        return nil
    }

    /// The section whose header sits under `point`, for drops that land on a
    /// header (the only way to reach a collapsed category).
    private func headerSection(at point: CGPoint) -> Int? {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            guard indexPath.section < sections.count,
                  let header = collectionView.supplementaryView(
                      forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath
                  ) else { continue }
            let frame = header.convert(header.bounds, to: collectionView)
            if frame.contains(point) {
                return indexPath.section
            }
        }
        return nil
    }

    private func leadingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard onSettings != nil,
              let id = dataSource.itemIdentifier(for: indexPath),
              let row = rowsByID[id] else { return nil }
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
              let id = dataSource.itemIdentifier(for: indexPath),
              rowsByID[id]?.showsDelete == true else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
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
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelect?(id)
    }
}

// MARK: - Drag & drop

extension ExerciseListController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard onMove != nil,
              let id = dataSource.itemIdentifier(for: indexPath) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: id.uuidString as NSString))
        item.localObject = id
        return [item]
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
        guard session.localDragSession != nil else {
            return UICollectionViewDropProposal(operation: .cancel)
        }
        if destinationIndexPath != nil {
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        if headerSection(at: session.location(in: collectionView)) != nil {
            return UICollectionViewDropProposal(operation: .move, intent: .unspecified)
        }
        return UICollectionViewDropProposal(operation: .cancel)
    }

    func collectionView(_ collectionView: UICollectionView,
                        performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let dropItem = coordinator.items.first,
              let id = dropItem.dragItem.localObject as? UUID,
              let source = location(of: id)
        else { return }

        // Resolve where the item was let go. The header hit-test comes first:
        // when the touch ends on a header no insertion gap was shown, but UIKit
        // still reports a (misleading) nearest-row destinationIndexPath.
        let destinationSection: Int
        var destinationItem: Int?
        if let headerHit = headerSection(at: coordinator.session.location(in: collectionView)) {
            destinationSection = headerHit
            destinationItem = nil
        } else if let indexPath = coordinator.destinationIndexPath, indexPath.section < sections.count {
            destinationSection = indexPath.section
            destinationItem = indexPath.item
        } else {
            return
        }

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
            // Dropped on an expanded category's header: append.
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
        rowsByID[id] = {
            var updated = moved
            updated.exercise.category = category
            return updated
        }()
        applySnapshot(animated: false, reconfiguring: [])
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
        if let pending = pendingSections {
            pendingSections = nil
            setSections(pending, animated: true)
        }
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
/// edge of its row. Notes are drawn in `.label` so they match the row text color.
private final class MIDIPatternView: UIView {
    private let notes: [MIDINote]

    init(notes: [MIDINote]) {
        self.notes = notes
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        isOpaque = false
        backgroundColor = .clear
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: MIDIPatternView, _) in
            self.setNeedsDisplay()
        }
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
        UIColor.label.setFill()
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

        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(font: headerDefaults.textProperties.font),
            forImageIn: .normal
        )
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        addButton.accessibilityLabel = "Add"
        addButton.isHidden = true
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)

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

    func configure(name: String, count: Int, isCollapsed: Bool, showsCount: Bool, animated: Bool) {
        nameLabel.text = name
        countLabel.text = "(\(count))"
        countLabel.isHidden = !showsCount || (!isCollapsed && count > 0)
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
