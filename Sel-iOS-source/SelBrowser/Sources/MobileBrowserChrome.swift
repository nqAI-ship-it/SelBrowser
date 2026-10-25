import UIKit

/// Native controls stay above WKWebView and do not expose the trusted shell bridge to sites.
@MainActor final class MobileBrowserChrome: NSObject, UITextFieldDelegate {
    let header = UIVisualEffectView(effect: BrowserGlass.containerEffect())
    let footer = BrowserGlassView(interactive: true)
    let addressField = UITextField()
    private let addressPill = BrowserGlassView(interactive: true)
    private let securityIcon = UIImageView()
    private let settingsButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let tabsButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)
    private let countLabel = UILabel()
    private var currentURL = "sel://newtab"
    private var currentIsPrivate = false
    private var settingsWidth: NSLayoutConstraint!
    private var headerRow: UIStackView!
    private weak var edgeScrollView: UIScrollView?
    var onNavigate: ((String) -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onHome: (() -> Void)?
    var onTabs: (() -> Void)?
    var onSettings: (() -> Void)?
    var onMenu: (() -> Void)?

    override init() {
        super.init()
        configureHeader()
        configureFooter()
    }

    private func configureHeader() {
        header.translatesAutoresizingMaskIntoConstraints = false
        header.accessibilityIdentifier = "mobileHeader"
        headerRow = UIStackView(arrangedSubviews: [addressPill, settingsButton])
        headerRow.axis = .horizontal; headerRow.spacing = 10; headerRow.alignment = .center
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.contentView.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.contentView.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: header.contentView.trailingAnchor),
            headerRow.topAnchor.constraint(equalTo: header.contentView.topAnchor),
            headerRow.bottomAnchor.constraint(equalTo: header.contentView.bottomAnchor),
            addressPill.heightAnchor.constraint(equalToConstant: 52)
        ])
        securityIcon.contentMode = .scaleAspectFit
        securityIcon.tintColor = .secondaryLabel
        securityIcon.translatesAutoresizingMaskIntoConstraints = false
        securityIcon.isAccessibilityElement = false
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.font = .preferredFont(forTextStyle: .body)
        addressField.adjustsFontForContentSizeCategory = true
        addressField.placeholder = "Поиск или адрес сайта"
        addressField.accessibilityLabel = "Поиск или адрес сайта"
        addressField.accessibilityIdentifier = "mobileAddress"
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.spellCheckingType = .no
        addressField.smartQuotesType = .no; addressField.smartDashesType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.delegate = self
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressPill.contentView.addSubview(securityIcon)
        addressPill.contentView.addSubview(addressField)
        NSLayoutConstraint.activate([
            securityIcon.leadingAnchor.constraint(equalTo: addressPill.contentView.leadingAnchor, constant: 16),
            securityIcon.centerYAnchor.constraint(equalTo: addressPill.contentView.centerYAnchor),
            securityIcon.widthAnchor.constraint(equalToConstant: 18),
            securityIcon.heightAnchor.constraint(equalToConstant: 18),
            addressField.leadingAnchor.constraint(equalTo: securityIcon.trailingAnchor, constant: 10),
            addressField.trailingAnchor.constraint(equalTo: addressPill.contentView.trailingAnchor, constant: -14),
            addressField.topAnchor.constraint(equalTo: addressPill.contentView.topAnchor, constant: 4),
            addressField.bottomAnchor.constraint(equalTo: addressPill.contentView.bottomAnchor, constant: -4)
        ])
        var profile = BrowserGlass.buttonConfiguration()
        profile.title = "S"; profile.cornerStyle = .capsule; profile.baseForegroundColor = .systemBlue
        profile.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes; result.font = UIFont.systemFont(ofSize: 18, weight: .semibold); return result
        }
        settingsButton.configuration = profile
        settingsWidth = settingsButton.widthAnchor.constraint(equalToConstant: 48)
        settingsWidth.priority = .defaultHigh
        settingsWidth.isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        settingsButton.accessibilityLabel = "Открыть настройки Sel"
        settingsButton.accessibilityIdentifier = "mobileSettings"
        settingsButton.addAction(UIAction { [weak self] _ in self?.addressField.resignFirstResponder(); self?.onSettings?() }, for: .touchUpInside)
    }

    private func configureFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.accessibilityIdentifier = "mobileBottomBar"
        let row = UIStackView(arrangedSubviews: [backButton, forwardButton, reloadButton, tabsButton, menuButton])
        row.axis = .horizontal; row.distribution = .fillEqually; row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        footer.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: footer.contentView.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: footer.contentView.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: footer.contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: footer.contentView.bottomAnchor, constant: -4)
        ])
        configureButton(backButton, symbol: "chevron.left", label: "Назад", id: "mobileBack")
        configureButton(forwardButton, symbol: "chevron.right", label: "Вперёд", id: "mobileForward")
        configureButton(reloadButton, symbol: "arrow.clockwise", label: "Обновить страницу", id: "mobileReload")
        configureButton(tabsButton, symbol: "square.on.square", label: "Вкладки", id: "mobileTabs")
        configureButton(menuButton, symbol: "ellipsis", label: "Меню браузера", id: "mobileMenu")
        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        forwardButton.addAction(UIAction { [weak self] _ in self?.onForward?() }, for: .touchUpInside)
        reloadButton.addAction(UIAction { [weak self] _ in self?.onReload?() }, for: .touchUpInside)
        tabsButton.addAction(UIAction { [weak self] _ in self?.addressField.resignFirstResponder(); self?.onTabs?() }, for: .touchUpInside)
        menuButton.showsMenuAsPrimaryAction = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 10, weight: .bold)
        countLabel.textAlignment = .center; countLabel.textColor = .white
        countLabel.backgroundColor = .systemBlue; countLabel.layer.cornerRadius = 8; countLabel.clipsToBounds = true
        countLabel.isAccessibilityElement = false
        tabsButton.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.centerXAnchor.constraint(equalTo: tabsButton.centerXAnchor, constant: 15),
            countLabel.centerYAnchor.constraint(equalTo: tabsButton.centerYAnchor, constant: -11),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            countLabel.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func configureButton(_ button: UIButton, symbol: String, label: String, id: String) {
        // One glass capsule surrounds this group; its buttons do not add overlapping glass layers.
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium))
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
        button.configuration = configuration
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.accessibilityLabel = label; button.accessibilityIdentifier = id
    }

    func setMenu(_ menu: UIMenu) { menuButton.menu = menu }

    func bindScrollView(_ scrollView: UIScrollView?) {
        guard edgeScrollView !== scrollView else { return }
        edgeScrollView = scrollView
        if #available(iOS 26.0, *) {
            for target in [header, footer] {
                for interaction in target.interactions where interaction is UIScrollEdgeElementContainerInteraction { target.removeInteraction(interaction) }
            }
            guard let scrollView = scrollView else { return }
            let top = UIScrollEdgeElementContainerInteraction(); top.scrollView = scrollView; top.edge = .top
            let bottom = UIScrollEdgeElementContainerInteraction(); bottom.scrollView = scrollView; bottom.edge = .bottom
            header.addInteraction(top); footer.addInteraction(bottom)
        }
    }

    func update(url: String, isPrivate: Bool, tabCount: Int, canBack: Bool, canForward: Bool, isLoading: Bool) {
        currentURL = url; currentIsPrivate = isPrivate
        if !addressField.isFirstResponder { addressField.text = displayAddress(url) }
        backButton.isEnabled = canBack; forwardButton.isEnabled = canForward
        reloadButton.isEnabled = BrowserAddress.isWeb(url)
        reloadButton.configuration?.image = UIImage(systemName: isLoading ? "xmark" : "arrow.clockwise")
        reloadButton.accessibilityLabel = isLoading ? "Остановить загрузку" : "Обновить страницу"
        countLabel.text = tabCount > 99 ? "99+" : String(tabCount)
        tabsButton.accessibilityValue = "\(tabCount) открытых вкладок" + (isPrivate ? ", приватный режим" : "")
        settingsButton.configuration?.title = isPrivate ? nil : "S"
        settingsButton.configuration?.image = isPrivate ? UIImage(systemName: "eyeglasses") : nil
        addressField.placeholder = isPrivate ? "Приватный поиск или адрес" : "Поиск или адрес сайта"
        let secure = URL(string: url)?.scheme?.lowercased() == "https"
        securityIcon.image = UIImage(systemName: isPrivate ? "eyeglasses" : secure ? "lock.fill" : BrowserAddress.isWeb(url) ? "exclamationmark.circle" : "magnifyingglass")
        addressField.accessibilityHint = secure ? "Соединение с сайтом использует HTTPS" : "Введите поисковый запрос или полный адрес"
    }

    func focusAddress() {
        addressField.text = BrowserAddress.isWeb(currentURL) ? currentURL : ""
        addressField.becomeFirstResponder(); addressField.selectAll(nil)
    }
    private func displayAddress(_ url: String) -> String { url.hasPrefix("sel://") ? "" : URL(string: url)?.host ?? url }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.text = BrowserAddress.isWeb(currentURL) ? currentURL : ""
        BrowserGlass.animate { [weak self] in
            guard let self = self else { return }
            self.settingsButton.alpha = 0; self.settingsButton.isHidden = true
            self.header.layoutIfNeeded()
        }
        DispatchQueue.main.async { [weak textField] in textField?.selectAll(nil) }
    }
    func textFieldDidEndEditing(_ textField: UITextField) {
        textField.text = displayAddress(currentURL)
        BrowserGlass.animate { [weak self] in
            guard let self = self else { return }
            self.settingsButton.isHidden = false; self.settingsButton.alpha = 1
            self.header.layoutIfNeeded()
        }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let value = textField.text ?? ""
        textField.resignFirstResponder(); onNavigate?(value)
        return true
    }
}
