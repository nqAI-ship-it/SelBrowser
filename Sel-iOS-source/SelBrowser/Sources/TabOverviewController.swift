import UIKit

struct TabOverviewItem {
    let id: String
    let title: String
    let url: String
    let favicon: UIImage?
    let preview: UIImage?
    let selected: Bool
    let pinned: Bool
}

/// A separate, native tab library. Page snapshots remain in memory and never leave the app.
final class TabOverviewController: UIViewController, UISearchBarDelegate, UICollectionViewDelegateFlowLayout, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onPrivacyChange: ((Bool) -> Void)?
    var onCloseAll: (() -> Void)?
    var onDone: (() -> Void)?
    var onBookmarks: (() -> Void)?
    var onMove: ((String, String) -> Void)?
    var normalInterfaceStyle: UIUserInterfaceStyle = .unspecified

    private var items: [TabOverviewItem] = []
    private var itemsByID: [String: TabOverviewItem] = [:]
    private var isPrivate: Bool
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["Вкладки", "Приватные"])
    private let searchBar = UISearchBar()
    private let moreButton = UIButton(type: .system)
    private let newButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let emptyTitle = UILabel()
    private let emptyDetail = UILabel()
    private let flowLayout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var lastGridWidth: CGFloat = 0
    private var headerStack: UIStackView!
    private var headingRow: UIStackView!
    private var headerTopConstraint: NSLayoutConstraint!

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.accessibilityIdentifier = "mobileTabOverview"
        view.tintColor = .systemBlue
        configureHeader()
        configureGrid()
        configureFooter()
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if abs(lastGridWidth - collectionView.bounds.width) > 0.5 {
            lastGridWidth = collectionView.bounds.width
            flowLayout.invalidateLayout()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            flowLayout.invalidateLayout()
        }
    }

    func update(items: [TabOverviewItem], isPrivate: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.update(items: items, isPrivate: isPrivate) }
            return
        }
        var knownIDs = Set<String>()
        self.items = items.filter { knownIDs.insert($0.id).inserted }
        self.itemsByID = Dictionary(uniqueKeysWithValues: self.items.map { ($0.id, $0) })
        self.isPrivate = isPrivate
        if isViewLoaded { render() }
    }

    func focusSearch() {
        loadViewIfNeeded()
        searchBar.becomeFirstResponder()
    }

    private func configureHeader() {
        titleLabel.text = "Вкладки"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle).withTraits(.traitBold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits.insert(.header)

        moreButton.configuration = BrowserGlass.buttonConfiguration()
        moreButton.configuration?.image = UIImage(systemName: "ellipsis")
        moreButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold), forImageIn: .normal)
        moreButton.accessibilityLabel = "Действия с вкладками"
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.configuration?.cornerStyle = .capsule

        let heading = UIStackView(arrangedSubviews: [titleLabel, UIView(), moreButton])
        headingRow = heading
        heading.alignment = .center
        heading.spacing = 12
        moreButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let moreHeight = moreButton.heightAnchor.constraint(equalToConstant: 44)
        // A hidden arranged row must be allowed to collapse to zero height.
        moreHeight.priority = .init(999)
        moreHeight.isActive = true

        modeControl.selectedSegmentIndex = isPrivate ? 1 : 0
        modeControl.accessibilityLabel = "Режим вкладок"
        modeControl.accessibilityIdentifier = "mobileTabMode"
        modeControl.addTarget(self, action: #selector(changeMode), for: .valueChanged)

        searchBar.delegate = self
        searchBar.placeholder = "Поиск по вкладкам"
        searchBar.searchBarStyle = .minimal
        searchBar.searchTextField.font = .preferredFont(forTextStyle: .body)
        searchBar.searchTextField.adjustsFontForContentSizeCategory = true
        searchBar.searchTextField.autocorrectionType = .no
        searchBar.searchTextField.returnKeyType = .done
        searchBar.accessibilityLabel = "Поиск по открытым вкладкам"

        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .secondaryLabel
        headerStack = UIStackView(arrangedSubviews: [heading, modeControl, searchBar, countLabel])
        headerStack.axis = .vertical
        headerStack.spacing = 8
        headerStack.setCustomSpacing(18, after: heading)
        headerStack.setCustomSpacing(2, after: searchBar)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerStack)

        headerTopConstraint = headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        let headingHeight = heading.heightAnchor.constraint(greaterThanOrEqualToConstant: 46)
        headingHeight.priority = .init(999)
        let modeHeight = modeControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        modeHeight.priority = .init(999)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            headerTopConstraint, headingHeight, modeHeight,
            searchBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
    }

    private func configureGrid() {
        flowLayout.minimumInteritemSpacing = 12
        flowLayout.minimumLineSpacing = 16
        flowLayout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.dragDelegate = self; collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.accessibilityIdentifier = "mobileTabGrid"
        collectionView.register(TabOverviewCell.self, forCellWithReuseIdentifier: TabOverviewCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 2),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])

        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] grid, path, id in
            guard let self = self,
                  let item = self.itemsByID[id],
                  let cell = grid.dequeueReusableCell(withReuseIdentifier: TabOverviewCell.reuseID, for: path) as? TabOverviewCell else { return nil }
            cell.configure(item)
            cell.onSelect = { [weak self] stableID in
                guard self?.itemsByID[stableID] != nil else { return }
                self?.onSelect?(stableID)
            }
            cell.onClose = { [weak self] stableID in
                guard self?.itemsByID[stableID] != nil else { return }
                self?.onClose?(stableID)
            }
            return cell
        }

        let emptyIcon = UIImageView(image: UIImage(systemName: "square.on.square"))
        emptyIcon.contentMode = .scaleAspectFit
        emptyIcon.tintColor = .tertiaryLabel
        emptyIcon.heightAnchor.constraint(equalToConstant: 54).isActive = true
        emptyTitle.font = .preferredFont(forTextStyle: .title2).withTraits(.traitBold)
        emptyTitle.adjustsFontForContentSizeCategory = true
        emptyTitle.textAlignment = .center
        emptyTitle.numberOfLines = 0
        emptyDetail.font = .preferredFont(forTextStyle: .body)
        emptyDetail.adjustsFontForContentSizeCategory = true
        emptyDetail.textAlignment = .center
        emptyDetail.textColor = .secondaryLabel
        emptyDetail.numberOfLines = 0
        let emptyStack = UIStackView(arrangedSubviews: [emptyIcon, emptyTitle, emptyDetail])
        emptyStack.axis = .vertical
        emptyStack.spacing = 12
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        let emptyContainer = UIView()
        emptyContainer.addSubview(emptyStack)
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: emptyContainer.leadingAnchor, constant: 28),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: emptyContainer.trailingAnchor, constant: -28),
            emptyStack.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        collectionView.backgroundView = emptyContainer
    }

    private func configureFooter() {
        let bar = UIVisualEffectView(effect: BrowserGlass.containerEffect())
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        var newConfiguration = BrowserGlass.buttonConfiguration(prominent: true)
        newConfiguration.title = "Новая вкладка"
        newConfiguration.image = UIImage(systemName: "plus")
        newConfiguration.imagePadding = 8
        newConfiguration.cornerStyle = .capsule
        newConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        newButton.configuration = newConfiguration
        newButton.accessibilityLabel = "Открыть новую вкладку"
        newButton.accessibilityIdentifier = "mobileNewTab"
        newButton.addTarget(self, action: #selector(createTab), for: .touchUpInside)

        var doneConfiguration = BrowserGlass.buttonConfiguration()
        doneConfiguration.title = "Готово"
        doneConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        doneButton.configuration = doneConfiguration
        doneButton.accessibilityLabel = "Вернуться к открытой странице"
        doneButton.accessibilityIdentifier = "mobileTabsDone"
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [newButton, UIView(), doneButton])
        buttons.alignment = .center
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(buttons)
        let separator = UIView()
        separator.backgroundColor = .clear
        separator.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(separator)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 72),
            buttons.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            newButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bar.topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            collectionView.bottomAnchor.constraint(equalTo: bar.topAnchor)
        ])
    }

    private var filteredItems: [TabOverviewItem] {
        let query = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { ($0.title + " " + $0.url).localizedCaseInsensitiveContains(query) }
    }

    private func render() {
        overrideUserInterfaceStyle = isPrivate ? .dark : normalInterfaceStyle
        modeControl.selectedSegmentIndex = isPrivate ? 1 : 0
        titleLabel.text = isPrivate ? "Приватные вкладки" : "Вкладки"
        titleLabel.font = .preferredFont(forTextStyle: isPrivate ? .title1 : .largeTitle).withTraits(.traitBold)
        countLabel.text = isPrivate ? "Приватный режим · \(items.count)" : "Открыто вкладок: \(items.count)"
        let visible = filteredItems
        let searching = !(searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        emptyTitle.text = searching ? "Ничего не найдено" : isPrivate ? "Приватных вкладок пока нет" : "Открытых вкладок пока нет"
        emptyDetail.text = searching ? "Попробуйте другое название или адрес." : isPrivate ? "История и cookie этого режима не сохраняются после закрытия приватной сессии." : "Откройте новую вкладку, чтобы начать поиск."
        collectionView.backgroundView?.isHidden = !visible.isEmpty

        let oldIDs = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(visible.map { $0.id })
        snapshot.reconfigureItems(visible.map { $0.id }.filter { oldIDs.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)

        let bookmarks = UIAction(title: "Закладки", image: UIImage(systemName: "bookmark")) { [weak self] _ in self?.onBookmarks?() }
        let closeAll = UIAction(title: isPrivate ? "Закрыть приватные вкладки" : "Закрыть все вкладки", image: UIImage(systemName: "xmark.square"), attributes: items.isEmpty ? [.disabled, .destructive] : [.destructive]) { [weak self] _ in self?.onCloseAll?() }
        moreButton.menu = UIMenu(children: [bookmarks, closeAll])
    }

    @objc private func changeMode() {
        let requestedPrivate = modeControl.selectedSegmentIndex == 1
        guard requestedPrivate != isPrivate else { return }
        // Release the previous mode's snapshots before the host supplies the other mode.
        items.removeAll()
        itemsByID.removeAll()
        isPrivate = requestedPrivate
        searchBar.text = ""
        render()
        onPrivacyChange?(requestedPrivate)
    }

    @objc private func createTab() {
        searchBar.resignFirstResponder()
        onNewTab?()
    }

    @objc private func finish() {
        searchBar.resignFirstResponder()
        if let onDone = onDone { onDone() } else { dismiss(animated: true) }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { render() }
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) { setSearchEditing(true) }
    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) { setSearchEditing(false) }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }

    private func setSearchEditing(_ editing: Bool) {
        // Keep the result grid usable above the keyboard, including short landscape windows.
        headingRow.isHidden = editing
        modeControl.isHidden = editing
        countLabel.isHidden = editing
        headerTopConstraint.constant = editing ? 4 : 12
        view.setNeedsLayout()
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collectionView.bounds.width
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let columns: CGFloat = accessible ? 1 : width >= 1000 ? 4 : width >= 700 ? 3 : 2
        let itemWidth = floor(max(1, (width - 32 - (columns - 1) * 12) / columns))
        let headerHeight = max(62, ceil(UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection).lineHeight + UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traitCollection).lineHeight + 27))
        return CGSize(width: itemWidth, height: min(340, itemWidth * 1.12) + headerHeight + 4)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), itemsByID[id] != nil else { return }
        onSelect?(id)
    }

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard let id = dataSource.itemIdentifier(for: indexPath), itemsByID[id] != nil else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: id as NSString))
        item.localObject = id
        return [item]
    }
    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool { session.localDragSession != nil }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        UICollectionViewDropProposal(operation: session.localDragSession == nil ? .forbidden : .move, intent: .insertAtDestinationIndexPath)
    }
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let item = coordinator.items.first, let id = item.dragItem.localObject as? String,
              itemsByID[id] != nil, let destination = coordinator.destinationIndexPath,
              let target = dataSource.itemIdentifier(for: destination), target != id else { return }
        onMove?(id, target)
        coordinator.drop(item.dragItem, toItemAt: destination)
    }
}

private final class TabOverviewCell: UICollectionViewCell {
    static let reuseID = "TabOverviewCell"
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    private var representedID: String?
    private let titleLabel = UILabel()
    private let domainLabel = UILabel()
    private let faviconView = UIImageView()
    private let previewView = UIImageView()
    private let placeholderLabel = UILabel()
    private let placeholderIcon = UIImageView()
    private let previewContainer = UIView()
    private let pinView = UIImageView(image: UIImage(systemName: "pin.fill"))
    private let openButton = UIButton(type: .custom)
    private let closeButton = UIButton(type: .system)
    private var previewTopConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 20
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        faviconView.contentMode = .scaleAspectFit
        faviconView.tintColor = .secondaryLabel
        faviconView.layer.cornerRadius = 4
        faviconView.clipsToBounds = true
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        domainLabel.font = .preferredFont(forTextStyle: .caption2)
        domainLabel.adjustsFontForContentSizeCategory = true
        domainLabel.textColor = .secondaryLabel
        domainLabel.numberOfLines = 1
        let labels = UIStackView(arrangedSubviews: [titleLabel, domainLabel])
        labels.axis = .vertical
        labels.spacing = 3
        labels.isUserInteractionEnabled = false
        pinView.tintColor = .secondaryLabel
        pinView.contentMode = .scaleAspectFit

        previewContainer.backgroundColor = .tertiarySystemFill
        previewContainer.isUserInteractionEnabled = false
        previewContainer.clipsToBounds = true
        previewView.contentMode = .scaleAspectFill
        previewView.clipsToBounds = true
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.tintColor = .systemBlue
        placeholderLabel.font = .preferredFont(forTextStyle: .caption1)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.textAlignment = .center
        placeholderLabel.numberOfLines = 2
        let placeholder = UIStackView(arrangedSubviews: [placeholderIcon, placeholderLabel])
        placeholder.axis = .vertical
        placeholder.spacing = 14
        placeholder.alignment = .center
        placeholder.isUserInteractionEnabled = false

        [faviconView, labels, pinView, previewContainer, openButton, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        previewView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(placeholder)
        previewContainer.addSubview(previewView)

        openButton.addTarget(self, action: #selector(openTab), for: .touchUpInside)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 12, weight: .bold), forImageIn: .normal)
        closeButton.tintColor = .label
        closeButton.addTarget(self, action: #selector(closeTab), for: .touchUpInside)

        previewTopConstraint = previewContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 62)
        NSLayoutConstraint.activate([
            faviconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            faviconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            faviconView.widthAnchor.constraint(equalToConstant: 20),
            faviconView.heightAnchor.constraint(equalToConstant: 20),
            labels.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: 2),
            labels.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: previewContainer.topAnchor, constant: -8),
            closeButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            pinView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            pinView.bottomAnchor.constraint(equalTo: previewContainer.topAnchor, constant: -7),
            pinView.widthAnchor.constraint(equalToConstant: 12),
            pinView.heightAnchor.constraint(equalToConstant: 12),
            previewContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            previewContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            previewContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            previewTopConstraint,
            previewView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: previewContainer.leadingAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: previewContainer.trailingAnchor, constant: -12),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 44),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 44),
            openButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            openButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            openButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            openButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        previewContainer.layer.cornerRadius = 15
        previewContainer.layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        onClose = nil
        onSelect = nil
        faviconView.image = nil
        previewView.image = nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        contentView.layer.borderColor = (openButton.accessibilityTraits.contains(.selected) ? UIColor.systemBlue : UIColor.separator.withAlphaComponent(0.18)).cgColor
        updateHeaderHeight()
    }

    func configure(_ item: TabOverviewItem) {
        representedID = item.id
        let title = item.title.isEmpty ? "Новая вкладка" : item.title
        let host = URL(string: item.url)?.host?.replacingOccurrences(of: "www.", with: "")
        let internalPage = item.url.hasPrefix("sel://")
        titleLabel.text = title
        domainLabel.text = internalPage ? "Sel" : host ?? item.url
        faviconView.image = item.favicon ?? UIImage(systemName: internalPage ? "sparkle.magnifyingglass" : "globe")
        previewView.image = item.preview
        previewView.isHidden = item.preview == nil
        placeholderIcon.image = item.favicon ?? UIImage(systemName: internalPage ? "sparkle.magnifyingglass" : "globe")
        placeholderLabel.text = internalPage ? "Поиск в Sel" : host ?? title
        pinView.isHidden = !item.pinned
        contentView.layer.borderWidth = item.selected ? 2.5 : 0.5
        contentView.layer.borderColor = (item.selected ? UIColor.systemBlue : UIColor.separator.withAlphaComponent(0.18)).cgColor
        openButton.accessibilityLabel = title + (host.map { ", " + $0 } ?? "")
        openButton.accessibilityHint = "Открывает эту вкладку"
        openButton.accessibilityTraits = item.selected ? [.button, .selected] : [.button]
        closeButton.accessibilityLabel = "Закрыть вкладку «\(title)»"
        closeButton.accessibilityHint = "Другие вкладки останутся открытыми"
        accessibilityElements = [openButton, closeButton]
        updateHeaderHeight()
    }

    private func updateHeaderHeight() {
        previewTopConstraint?.constant = max(62, ceil(UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection).lineHeight + UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traitCollection).lineHeight + 27))
    }

    @objc private func openTab() {
        guard let id = representedID else { return }
        onSelect?(id)
    }

    @objc private func closeTab() {
        guard let id = representedID else { return }
        onClose?(id)
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
