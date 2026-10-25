import UIKit

/// Settings stay outside website views. Every change is applied by the browser host.
final class MobileSettingsController: UITableViewController, UISearchResultsUpdating {
    var onSettingsChange: ((BrowserSettings) -> Void)?
    /// The host dismisses this controller before presenting the requested data view.
    var onAction: ((String) -> Void)?
    var onDone: (() -> Void)?

    private var settings: BrowserSettings
    private let isPrivate: Bool
    private let searchController = UISearchController(searchResultsController: nil)
    private var displayedSections: [SettingsSection] = []
    private var profileHeader: UIView?

    private enum SettingsRow: CaseIterable, Equatable {
        case searchEngine, restoreSession, closeTabBehavior, theme, zoom
        case bookmarks, history, downloads, clearData, about

        var title: String {
            switch self {
            case .searchEngine: return "Поисковая система"
            case .restoreSession: return "Продолжать с открытых вкладок"
            case .closeTabBehavior: return "После закрытия вкладки"
            case .theme: return "Оформление"
            case .zoom: return "Масштаб страниц"
            case .bookmarks: return "Закладки"
            case .history: return "История"
            case .downloads: return "Загрузки"
            case .clearData: return "Очистить данные браузера"
            case .about: return "О браузере Sel"
            }
        }

        var symbol: String {
            switch self {
            case .searchEngine: return "magnifyingglass"
            case .restoreSession: return "arrow.clockwise.circle"
            case .closeTabBehavior: return "rectangle.on.rectangle"
            case .theme: return "circle.lefthalf.filled"
            case .zoom: return "textformat.size"
            case .bookmarks: return "bookmark"
            case .history: return "clock.arrow.circlepath"
            case .downloads: return "arrow.down.circle"
            case .clearData: return "trash"
            case .about: return "info.circle"
            }
        }
    }

    private struct SettingsSection {
        let title: String
        let footer: String?
        let rows: [SettingsRow]
    }

    init(settings: BrowserSettings, isPrivate: Bool) {
        self.settings = settings
        self.isPrivate = isPrivate
        super.init(style: .insetGrouped)
        title = "Настройки"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Готово", style: .done, target: self, action: #selector(done))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "ios.settings.done"
        navigationItem.backButtonTitle = "Настройки"
        view.tintColor = .systemBlue
        navigationController?.view.tintColor = .systemBlue
        tableView.backgroundColor = .systemGroupedBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "ios.settings.list"

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Поиск в настройках"
        searchController.searchBar.accessibilityIdentifier = "ios.settings.search"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        profileHeader = makeProfileHeader()
        applyTheme()
        reloadSections()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyTheme()
        tableView.reloadData()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let size = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if abs(header.frame.width - width) > 0.5 || abs(header.frame.height - size.height) > 0.5 {
            header.frame.size = CGSize(width: width, height: size.height)
            tableView.tableHeaderView = header
        }
    }

    @objc private func done() {
        searchController.isActive = false
        if let onDone = onDone { onDone() }
        else { dismiss(animated: true) }
    }

    private var sections: [SettingsSection] {
        [
            SettingsSection(
                title: "Браузер",
                footer: isPrivate ? "Приватные вкладки не восстанавливаются после завершения приложения." : "Открытые обычные вкладки можно восстановить при следующем запуске Sel.",
                rows: [.searchEngine, .restoreSession, .closeTabBehavior]
            ),
            SettingsSection(title: "Оформление", footer: "Масштаб применяется к сайтам. Размер элементов интерфейса учитывает настройки текста iPhone.", rows: [.theme, .zoom]),
            SettingsSection(title: "Ваши данные", footer: isPrivate ? "История приватного просмотра не сохраняется. Загруженные файлы остаются на устройстве." : nil, rows: [.bookmarks, .history, .downloads, .clearData]),
            SettingsSection(title: "Приложение", footer: versionDescription, rows: [.about])
        ]
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Sel для iOS · \(version) (\(build))\nWebKit · WKWebView"
    }

    private var query: String { (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    func updateSearchResults(for searchController: UISearchController) { reloadSections() }

    private func reloadSections() {
        let text = query
        displayedSections = sections.compactMap { section in
            let rows = section.rows.filter { row in
                text.isEmpty || (section.title + " " + row.title + " " + detail(for: row)).localizedCaseInsensitiveContains(text)
            }
            return rows.isEmpty ? nil : SettingsSection(title: section.title, footer: section.footer, rows: rows)
        }
        tableView.tableHeaderView = text.isEmpty ? profileHeader : nil
        if displayedSections.isEmpty {
            tableView.backgroundView = makeEmptySearchView()
        } else {
            tableView.backgroundView = nil
        }
        tableView.reloadData()
        view.setNeedsLayout()
    }

    private func makeEmptySearchView() -> UIView {
        let wrapper = UIView()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Ничего не найдено\nПопробуйте другое название настройки."
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 28),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -28),
            label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
        ])
        return wrapper
    }

    private func makeProfileHeader() -> UIView {
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 138))
        let avatar = UILabel()
        avatar.text = "S"
        avatar.font = .systemFont(ofSize: 26, weight: .bold)
        avatar.textColor = .white
        avatar.textAlignment = .center
        avatar.backgroundColor = .systemBlue
        avatar.layer.cornerRadius = 28
        avatar.clipsToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 56).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 56).isActive = true
        avatar.isAccessibilityElement = false

        let name = UILabel()
        name.text = "Sel"
        name.font = .preferredFont(forTextStyle: .title2)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = .label
        name.numberOfLines = 0
        let subtitle = UILabel()
        subtitle.text = isPrivate ? "Настройки приватного просмотра" : "Ваш браузер на iPhone и iPad"
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [name, subtitle])
        text.axis = .vertical
        text.spacing = 4
        let row = UIStackView(arrangedSubviews: [avatar, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 28),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -28),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 18),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -20)
        ])
        return wrapper
    }

    private func detail(for row: SettingsRow) -> String {
        switch row {
        case .searchEngine: return Self.engineTitle(settings.searchEngine)
        case .restoreSession: return isPrivate ? "Только обычные вкладки" : (settings.restoreSession ? "Включено" : "Выключено")
        case .closeTabBehavior:
            switch settings.closeTabBehavior {
            case "left": return "Перейти к вкладке слева"
            case "recent": return "Перейти к последней открытой"
            default: return "Перейти к вкладке справа"
            }
        case .theme:
            switch settings.theme {
            case "dark": return "Тёмное"
            case "wc2026": return "Футбол 2026"
            default: return "Светлое"
            }
        case .zoom: return "\(settings.defaultZoomPercent)%"
        case .bookmarks: return "Сохранённые страницы"
        case .history: return isPrivate ? "История этого режима не сохраняется" : "Недавно открытые сайты"
        case .downloads: return "Файлы на этом устройстве"
        case .clearData: return "История, cookie и кеш"
        case .about: return "Версия и сведения о приложении"
        }
    }

    private static func engineTitle(_ value: String) -> String {
        switch value {
        case "google": return "Google"
        case "duckduckgo": return "DuckDuckGo"
        default: return "Яндекс"
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { displayedSections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { displayedSections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { displayedSections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { displayedSections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = displayedSections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = detail(for: row)
        content.image = UIImage(systemName: row.symbol)
        content.imageProperties.tintColor = row == .clearData ? .systemRed : .systemBlue
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        content.textProperties.color = row == .clearData ? .systemRed : .label
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "ios.settings.\(row)"
        cell.accessoryType = .disclosureIndicator

        if row == .restoreSession {
            let toggle = UISwitch()
            toggle.isOn = settings.restoreSession
            toggle.isEnabled = !isPrivate
            toggle.onTintColor = .systemBlue
            toggle.accessibilityLabel = row.title
            toggle.accessibilityHint = isPrivate ? "Доступно для обычных вкладок" : "Восстанавливает обычные вкладки при запуске браузера"
            toggle.accessibilityIdentifier = "ios.settings.restoreSession.switch"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self = self, let toggle = toggle else { return }
                self.settings.restoreSession = toggle.isOn
                self.commit()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch displayedSections[indexPath.section].rows[indexPath.row] {
        case .searchEngine:
            showChoices(title: "Поисковая система", selected: settings.searchEngine, choices: [
                .init(value: "google", title: "Google"),
                .init(value: "yandex", title: "Яндекс"),
                .init(value: "duckduckgo", title: "DuckDuckGo")
            ]) { [weak self] value in self?.settings.searchEngine = value; self?.commit() }
        case .theme:
            showChoices(title: "Оформление", selected: settings.theme, choices: [
                .init(value: "light", title: "Светлое"),
                .init(value: "dark", title: "Тёмное"),
                .init(value: "wc2026", title: "Футбол 2026")
            ]) { [weak self] value in self?.settings.theme = value; self?.commit() }
        case .closeTabBehavior:
            showChoices(title: "После закрытия вкладки", selected: settings.closeTabBehavior, choices: [
                .init(value: "right", title: "Перейти к вкладке справа"),
                .init(value: "left", title: "Перейти к вкладке слева"),
                .init(value: "recent", title: "Перейти к последней открытой")
            ]) { [weak self] value in self?.settings.closeTabBehavior = value; self?.commit() }
        case .zoom:
            let values = Set([50, 75, 90, 100, 110, 125, 150, 175, 200, settings.defaultZoomPercent]).sorted()
            showChoices(title: "Масштаб страниц", selected: String(settings.defaultZoomPercent), choices: values.map {
                MobileSettingsChoice(value: String($0), title: $0 == 100 ? "100% — стандартный" : "\($0)%")
            }) { [weak self] value in
                guard let percent = Int(value), (50...200).contains(percent) else { return }
                self?.settings.defaultZoomPercent = percent
                self?.commit()
            }
        case .restoreSession: break
        case .bookmarks: requestAction("bookmarks")
        case .history: requestAction("history")
        case .downloads: requestAction("downloads")
        case .clearData: requestAction("clearData")
        case .about: requestAction("about")
        }
    }

    private func requestAction(_ action: String) {
        searchController.isActive = false
        onAction?(action)
    }

    private func showChoices(title: String, selected: String, choices: [MobileSettingsChoice], changed: @escaping (String) -> Void) {
        let controller = MobileSettingsChoiceController(title: title, choices: choices, selected: selected)
        controller.onSelect = changed
        navigationController?.pushViewController(controller, animated: true)
    }

    private func commit() {
        applyTheme()
        reloadSections()
        onSettingsChange?(settings)
    }

    private func applyTheme() {
        let style: UIUserInterfaceStyle = settings.theme == "light" ? .light : .dark
        overrideUserInterfaceStyle = style
        navigationController?.overrideUserInterfaceStyle = style
    }
}

private struct MobileSettingsChoice {
    let value: String
    let title: String
}

private final class MobileSettingsChoiceController: UITableViewController {
    private let choices: [MobileSettingsChoice]
    private var selected: String
    var onSelect: ((String) -> Void)?

    init(title: String, choices: [MobileSettingsChoice], selected: String) {
        self.choices = choices
        self.selected = selected
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.accessibilityIdentifier = "ios.settings.choices"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { choices.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let choice = choices[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = choice.title
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = selected == choice.value ? .checkmark : .none
        cell.accessibilityIdentifier = "ios.settings.choice.\(choice.value)"
        cell.accessibilityTraits = selected == choice.value ? [.button, .selected] : [.button]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let choice = choices[indexPath.row]
        selected = choice.value
        tableView.reloadData()
        UISelectionFeedbackGenerator().selectionChanged()
        onSelect?(choice.value)
    }
}
