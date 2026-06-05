import AppKit
import Darwin
import Network
import WebKit

private let appName = "NorthStar"
private let settingsTitle = "Настройки"
private let blankURL = URL(string: "about:blank")!
private let northStarSearchScheme = "northstar-search"
private let northStarSettingsScheme = "northstar-settings"

@main
private enum NorthStarApplication {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate

        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu(appDelegate: delegate)
        AppPreferences.shared.theme.apply()
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        newWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindow(nil)
        }

        return true
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = BrowserWindowController()
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
        }

        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init() {
        let viewController = BrowserViewController()
        let window = NSWindow(contentViewController: viewController)
        window.title = appName
        window.setContentSize(NSSize(width: 1360, height: 840))
        window.minSize = NSSize(width: 920, height: 560)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

@MainActor
private final class BrowserViewController: NSViewController {
    private let preferences = AppPreferences.shared

    private let tabBarView = NSVisualEffectView()
    private let tabBarHeaderView = NSView()
    private let tabBarTitle = NSTextField(labelWithString: "Вкладки")
    private let newTabButton = IconButton(symbolName: "plus", tooltip: "Новая вкладка", width: 28, height: 26)
    private let tabScrollView = NSScrollView()
    private let tabStack = FlippedStackView()

    private let browserContentView = NSView()
    private let toolbarView = NSVisualEffectView()
    private let brandTitleField = NSTextField(labelWithString: appName)
    private let webContainerView = NSView()

    private let backButton = IconButton(symbolName: "chevron.left", tooltip: "Назад")
    private let forwardButton = IconButton(symbolName: "chevron.right", tooltip: "Вперёд")
    private let homeButton = IconButton(symbolName: "house", tooltip: "Домой")
    private let reloadButton = IconButton(symbolName: "arrow.clockwise", tooltip: "Обновить")
    private let settingsButton = IconButton(symbolName: "gearshape", tooltip: settingsTitle)
    private let addressField = NSTextField()
    private let searchEnginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let networkPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progressIndicator = NSProgressIndicator()

    private var placementConstraints: [NSLayoutConstraint] = []
    private var tabBarContentConstraints: [NSLayoutConstraint] = []
    private var tabStackCrossAxisConstraint: NSLayoutConstraint?
    private var toolbarHeightConstraint: NSLayoutConstraint?
    private var activeDownloads: [ObjectIdentifier: UUID] = [:]
    private var tabs: [BrowserTab] = []
    private var activeTabID: UUID?

    private var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabID }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureLayout()
        configureTabBar()
        configureToolbar()
        observePreferences()
        applyPreferences(redrawHomeTabs: false)
        addTab(profile: .system, url: nil, activate: true)
    }

    @objc func newTabCommand(_ sender: Any?) {
        addTab(profile: activeTab?.profile ?? .system, url: nil, activate: true)
    }

    @objc func closeTabCommand(_ sender: Any?) {
        guard let id = activeTabID else { return }
        closeTab(id: id)
    }

    @objc func nextTabCommand(_ sender: Any?) {
        selectAdjacentTab(offset: 1)
    }

    @objc func previousTabCommand(_ sender: Any?) {
        selectAdjacentTab(offset: -1)
    }

    @objc func goBackCommand(_ sender: Any?) {
        if activeTab?.webView.canGoBack == true {
            activeTab?.webView.goBack()
        }
    }

    @objc func goForwardCommand(_ sender: Any?) {
        if activeTab?.webView.canGoForward == true {
            activeTab?.webView.goForward()
        }
    }

    @objc func reloadCommand(_ sender: Any?) {
        guard let tab = activeTab else { return }

        if tab.webView.isLoading {
            tab.webView.stopLoading()
        } else if tab.isShowingHome {
            showHome(in: tab)
        } else if tab.isShowingSettings {
            showSettings(in: tab)
        } else {
            tab.webView.reload()
        }
    }

    @objc func focusLocation(_ sender: Any?) {
        view.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc func showSettingsCommand(_ sender: Any?) {
        openSettingsTab()
    }

    @objc private func goHome(_ sender: Any?) {
        guard let tab = activeTab else { return }
        showHome(in: tab)
    }

    @objc private func loadTypedAddress(_ sender: Any?) {
        guard let tab = activeTab else { return }

        let trimmed = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            showHome(in: tab)
            return
        }

        guard let url = URLParser.url(from: trimmed, searchEngine: preferences.searchEngine) else {
            NSSound.beep()
            return
        }

        load(url, in: tab)
    }

    @objc private func addTabFromButton(_ sender: Any?) {
        newTabCommand(sender)
    }

    @objc private func networkSelectionChanged(_ sender: Any?) {
        let index = networkPopup.indexOfSelectedItem
        guard NetworkProfile.allCases.indices.contains(index),
              let tab = activeTab else {
            return
        }

        replace(tab: tab, with: NetworkProfile.allCases[index])
    }

    @objc private func searchEngineSelectionChanged(_ sender: Any?) {
        let index = searchEnginePopup.indexOfSelectedItem
        guard SearchEngine.allCases.indices.contains(index) else { return }
        preferences.searchEngine = SearchEngine.allCases[index]
    }

    @objc private func preferencesChanged(_ notification: Notification) {
        applyPreferences(redrawHomeTabs: true)
    }

    private func configureLayout() {
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        tabBarView.material = .sidebar
        tabBarView.blendingMode = .withinWindow
        tabBarView.state = .active

        browserContentView.translatesAutoresizingMaskIntoConstraints = false
        browserContentView.wantsLayer = true

        view.addSubview(tabBarView)
        view.addSubview(browserContentView)
    }

    private func configureTabBar() {
        tabBarHeaderView.translatesAutoresizingMaskIntoConstraints = false

        tabBarTitle.translatesAutoresizingMaskIntoConstraints = false
        tabBarTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        tabBarTitle.textColor = .secondaryLabelColor
        tabBarTitle.lineBreakMode = .byTruncatingTail

        newTabButton.target = self
        newTabButton.action = #selector(addTabFromButton(_:))
        newTabButton.bezelStyle = .inline
        newTabButton.isBordered = false

        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.drawsBackground = false
        tabScrollView.autohidesScrollers = true
        tabScrollView.borderType = .noBorder

        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabStack.spacing = 10
        tabStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)

        tabScrollView.documentView = tabStack

        tabBarView.addSubview(tabBarHeaderView)
        tabBarView.addSubview(tabScrollView)
        tabBarHeaderView.addSubview(tabBarTitle)
        tabBarHeaderView.addSubview(newTabButton)
    }

    private func configureToolbar() {
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.material = .headerView
        toolbarView.blendingMode = .withinWindow
        toolbarView.state = .active

        brandTitleField.translatesAutoresizingMaskIntoConstraints = false
        brandTitleField.font = .systemFont(ofSize: 18, weight: .bold)
        brandTitleField.lineBreakMode = .byTruncatingTail
        brandTitleField.setContentCompressionResistancePriority(.required, for: .horizontal)

        webContainerView.translatesAutoresizingMaskIntoConstraints = false
        webContainerView.wantsLayer = true

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: 14)
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.placeholderString = "Поиск или адрес сайта"
        addressField.target = self
        addressField.action = #selector(loadTypedAddress(_:))

        searchEnginePopup.translatesAutoresizingMaskIntoConstraints = false
        searchEnginePopup.controlSize = .regular
        searchEnginePopup.font = .systemFont(ofSize: 13)
        searchEnginePopup.target = self
        searchEnginePopup.action = #selector(searchEngineSelectionChanged(_:))
        searchEnginePopup.toolTip = "Поисковая система"
        searchEnginePopup.removeAllItems()
        searchEnginePopup.addItems(withTitles: SearchEngine.allCases.map(\.title))

        networkPopup.translatesAutoresizingMaskIntoConstraints = false
        networkPopup.controlSize = .regular
        networkPopup.font = .systemFont(ofSize: 13)
        networkPopup.target = self
        networkPopup.action = #selector(networkSelectionChanged(_:))
        networkPopup.toolTip = "Сеть"
        networkPopup.removeAllItems()
        networkPopup.addItems(withTitles: NetworkProfile.allCases.map(\.title))

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.controlSize = .small
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.isIndeterminate = false
        progressIndicator.isHidden = true

        backButton.target = self
        backButton.action = #selector(goBackCommand(_:))
        forwardButton.target = self
        forwardButton.action = #selector(goForwardCommand(_:))
        homeButton.target = self
        homeButton.action = #selector(goHome(_:))
        reloadButton.target = self
        reloadButton.action = #selector(reloadCommand(_:))
        settingsButton.target = self
        settingsButton.action = #selector(showSettingsCommand(_:))

        browserContentView.addSubview(toolbarView)
        browserContentView.addSubview(webContainerView)

        [brandTitleField, backButton, forwardButton, homeButton, addressField, searchEnginePopup, networkPopup, reloadButton, settingsButton, progressIndicator].forEach {
            toolbarView.addSubview($0)
        }

        let toolbarHeight = toolbarView.heightAnchor.constraint(equalToConstant: preferences.design.toolbarHeight)
        toolbarHeightConstraint = toolbarHeight

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: browserContentView.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: browserContentView.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: browserContentView.trailingAnchor),
            toolbarHeight,

            webContainerView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            webContainerView.leadingAnchor.constraint(equalTo: browserContentView.leadingAnchor),
            webContainerView.trailingAnchor.constraint(equalTo: browserContentView.trailingAnchor),
            webContainerView.bottomAnchor.constraint(equalTo: browserContentView.bottomAnchor),

            brandTitleField.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 16),
            brandTitleField.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor, constant: -1),
            brandTitleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 94),

            backButton.leadingAnchor.constraint(equalTo: brandTitleField.trailingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor, constant: -1),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            forwardButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            homeButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 8),
            homeButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            settingsButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -12),
            settingsButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            reloadButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -8),
            reloadButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            networkPopup.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -10),
            networkPopup.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            networkPopup.widthAnchor.constraint(equalToConstant: 118),

            searchEnginePopup.trailingAnchor.constraint(equalTo: networkPopup.leadingAnchor, constant: -10),
            searchEnginePopup.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            searchEnginePopup.widthAnchor.constraint(equalToConstant: 132),

            addressField.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: 12),
            addressField.trailingAnchor.constraint(equalTo: searchEnginePopup.leadingAnchor, constant: -12),
            addressField.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 30),

            progressIndicator.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor),
            progressIndicator.bottomAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            progressIndicator.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    private func observePreferences() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged(_:)),
            name: AppPreferences.didChangeNotification,
            object: preferences
        )
    }

    private func applyPreferences(redrawHomeTabs: Bool) {
        preferences.theme.apply()
        toolbarHeightConstraint?.constant = preferences.design.toolbarHeight
        applyChromeTheme()
        applyTabPlacement(preferences.tabPlacement)

        if redrawHomeTabs {
            tabs.filter(\.isShowingHome).forEach { showHome(in: $0) }
            refreshSettingsTabs()
        }

        renderTabs()
        syncToolbar()
    }

    private func applyChromeTheme() {
        let colors = ChromePalette(theme: preferences.theme, colorScheme: preferences.colorScheme)
        view.layer?.backgroundColor = colors.window.cgColor
        browserContentView.layer?.backgroundColor = colors.window.cgColor
        webContainerView.layer?.backgroundColor = colors.webBackground.cgColor
        brandTitleField.textColor = colors.brand
        tabBarTitle.textColor = colors.secondaryText
    }

    private func applyTabPlacement(_ placement: TabPlacement) {
        NSLayoutConstraint.deactivate(placementConstraints)

        switch placement {
        case .left:
            placementConstraints = [
                tabBarView.topAnchor.constraint(equalTo: view.topAnchor),
                tabBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tabBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                tabBarView.widthAnchor.constraint(equalToConstant: preferences.design.verticalTabBarWidth),

                browserContentView.topAnchor.constraint(equalTo: view.topAnchor),
                browserContentView.leadingAnchor.constraint(equalTo: tabBarView.trailingAnchor),
                browserContentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                browserContentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ]
        case .right:
            placementConstraints = [
                browserContentView.topAnchor.constraint(equalTo: view.topAnchor),
                browserContentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                browserContentView.trailingAnchor.constraint(equalTo: tabBarView.leadingAnchor),
                browserContentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                tabBarView.topAnchor.constraint(equalTo: view.topAnchor),
                tabBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                tabBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                tabBarView.widthAnchor.constraint(equalToConstant: preferences.design.verticalTabBarWidth)
            ]
        case .top:
            placementConstraints = [
                tabBarView.topAnchor.constraint(equalTo: view.topAnchor),
                tabBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tabBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                tabBarView.heightAnchor.constraint(equalToConstant: preferences.design.horizontalTabBarHeight),

                browserContentView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
                browserContentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                browserContentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                browserContentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ]
        case .bottom:
            placementConstraints = [
                browserContentView.topAnchor.constraint(equalTo: view.topAnchor),
                browserContentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                browserContentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                browserContentView.bottomAnchor.constraint(equalTo: tabBarView.topAnchor),

                tabBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tabBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                tabBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                tabBarView.heightAnchor.constraint(equalToConstant: preferences.design.horizontalTabBarHeight)
            ]
        }

        NSLayoutConstraint.activate(placementConstraints)
        applyTabBarContentLayout(placement)
    }

    private func applyTabBarContentLayout(_ placement: TabPlacement) {
        NSLayoutConstraint.deactivate(tabBarContentConstraints)
        tabStackCrossAxisConstraint?.isActive = false

        let isHorizontal = placement.isHorizontal
        tabBarView.material = isHorizontal ? .headerView : .sidebar
        tabBarTitle.isHidden = isHorizontal
        tabBarTitle.stringValue = placement == .top ? appName : "Вкладки"
        tabStack.orientation = isHorizontal ? .horizontal : .vertical
        tabStack.alignment = isHorizontal ? .height : .width
        tabStack.spacing = isHorizontal ? preferences.design.horizontalTabSpacing : preferences.design.tabSpacing
        tabStack.edgeInsets = isHorizontal
            ? NSEdgeInsets(top: preferences.design.horizontalTabInset, left: 4, bottom: preferences.design.horizontalTabInset, right: 10)
            : NSEdgeInsets(top: 10, left: 12, bottom: 14, right: 12)
        tabScrollView.hasHorizontalScroller = isHorizontal
        tabScrollView.hasVerticalScroller = !isHorizontal

        if isHorizontal {
            tabBarContentConstraints = [
                tabBarHeaderView.topAnchor.constraint(equalTo: tabBarView.topAnchor),
                tabBarHeaderView.leadingAnchor.constraint(equalTo: tabBarView.leadingAnchor),
                tabBarHeaderView.bottomAnchor.constraint(equalTo: tabBarView.bottomAnchor),
                tabBarHeaderView.widthAnchor.constraint(equalToConstant: preferences.design.horizontalTabHeaderWidth),

                tabBarTitle.leadingAnchor.constraint(equalTo: tabBarHeaderView.leadingAnchor, constant: 16),
                tabBarTitle.centerYAnchor.constraint(equalTo: tabBarHeaderView.centerYAnchor),
                tabBarTitle.trailingAnchor.constraint(lessThanOrEqualTo: newTabButton.leadingAnchor, constant: -10),

                newTabButton.centerYAnchor.constraint(equalTo: tabBarHeaderView.centerYAnchor),
                newTabButton.trailingAnchor.constraint(equalTo: tabBarHeaderView.trailingAnchor, constant: -6),

                tabScrollView.topAnchor.constraint(equalTo: tabBarView.topAnchor),
                tabScrollView.leadingAnchor.constraint(equalTo: tabBarHeaderView.trailingAnchor),
                tabScrollView.trailingAnchor.constraint(equalTo: tabBarView.trailingAnchor),
                tabScrollView.bottomAnchor.constraint(equalTo: tabBarView.bottomAnchor)
            ]
            tabStackCrossAxisConstraint = tabStack.heightAnchor.constraint(equalTo: tabScrollView.contentView.heightAnchor)
        } else {
            tabBarContentConstraints = [
                tabBarHeaderView.topAnchor.constraint(equalTo: tabBarView.topAnchor),
                tabBarHeaderView.leadingAnchor.constraint(equalTo: tabBarView.leadingAnchor),
                tabBarHeaderView.trailingAnchor.constraint(equalTo: tabBarView.trailingAnchor),
                tabBarHeaderView.heightAnchor.constraint(equalToConstant: 48),

                tabBarTitle.leadingAnchor.constraint(equalTo: tabBarHeaderView.leadingAnchor, constant: 14),
                tabBarTitle.centerYAnchor.constraint(equalTo: tabBarHeaderView.centerYAnchor),
                tabBarTitle.trailingAnchor.constraint(lessThanOrEqualTo: newTabButton.leadingAnchor, constant: -10),

                newTabButton.centerYAnchor.constraint(equalTo: tabBarHeaderView.centerYAnchor),
                newTabButton.trailingAnchor.constraint(equalTo: tabBarHeaderView.trailingAnchor, constant: -12),

                tabScrollView.topAnchor.constraint(equalTo: tabBarHeaderView.bottomAnchor),
                tabScrollView.leadingAnchor.constraint(equalTo: tabBarView.leadingAnchor),
                tabScrollView.trailingAnchor.constraint(equalTo: tabBarView.trailingAnchor),
                tabScrollView.bottomAnchor.constraint(equalTo: tabBarView.bottomAnchor)
            ]
            tabStackCrossAxisConstraint = tabStack.widthAnchor.constraint(equalTo: tabScrollView.contentView.widthAnchor)
        }

        NSLayoutConstraint.activate(tabBarContentConstraints)
        tabStackCrossAxisConstraint?.isActive = true
    }

    private func addTab(profile: NetworkProfile, url: URL?, activate: Bool) {
        let tab = makeTab(profile: profile)
        tabs.append(tab)

        if activate || activeTabID == nil {
            activeTabID = tab.id
            showActiveTab()
        }

        renderTabs()
        syncToolbar()

        if let url {
            load(url, in: tab)
        } else {
            showHome(in: tab)
        }
    }

    private func makeTab(profile: NetworkProfile) -> BrowserTab {
        let tab = BrowserTab(profile: profile)
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tab.onStateChange = { [weak self] changedTab in
            self?.tabStateDidChange(changedTab)
        }

        return tab
    }

    private func replace(tab oldTab: BrowserTab, with profile: NetworkProfile) {
        guard oldTab.profile != profile,
              let index = tabs.firstIndex(where: { $0.id == oldTab.id }) else {
            syncToolbar()
            return
        }

        let wasShowingSettings = oldTab.isShowingSettings
        let targetURL = oldTab.isShowingHome || oldTab.isShowingSettings ? nil : oldTab.url ?? oldTab.webView.url
        let newTab = makeTab(profile: profile)

        oldTab.close()
        oldTab.webView.removeFromSuperview()
        tabs[index] = newTab

        if activeTabID == oldTab.id {
            activeTabID = newTab.id
            showActiveTab()
        }

        renderTabs()
        syncToolbar()

        if wasShowingSettings {
            showSettings(in: newTab)
        } else if let targetURL, NetworkPolicy.allows(targetURL, profile: profile) {
            load(targetURL, in: newTab)
        } else {
            showHome(in: newTab)
        }
    }

    private func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingActiveTab = activeTabID == id
        let tab = tabs.remove(at: index)
        tab.close()
        tab.webView.removeFromSuperview()

        if tabs.isEmpty {
            view.window?.performClose(nil)
            return
        }

        if closingActiveTab {
            let nextIndex = min(index, tabs.count - 1)
            activeTabID = tabs[nextIndex].id
            showActiveTab()
        }

        renderTabs()
        syncToolbar()
    }

    private func selectAdjacentTab(offset: Int) {
        guard let activeTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeTabID }),
              !tabs.isEmpty else {
            return
        }

        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        activateTab(id: tabs[nextIndex].id)
    }

    private func activateTab(id: UUID) {
        guard activeTabID != id else { return }
        activeTabID = id
        showActiveTab()
        renderTabs()
        syncToolbar()
    }

    private func showActiveTab() {
        webContainerView.subviews.forEach { $0.removeFromSuperview() }

        guard let tab = activeTab else { return }

        let webView = tab.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainerView.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainerView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainerView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainerView.bottomAnchor)
        ])
    }

    private func renderTabs() {
        tabStack.arrangedSubviews.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let isHorizontal = preferences.tabPlacement.isHorizontal

        for tab in tabs {
            let row = TabRowView()
            row.configure(
                title: tab.displayTitle,
                detail: tab.profile.detail,
                isActive: tab.id == activeTabID,
                isHorizontal: isHorizontal,
                design: preferences.design
            )
            row.onSelect = { [weak self, id = tab.id] in
                self?.activateTab(id: id)
            }
            row.onClose = { [weak self, id = tab.id] in
                self?.closeTab(id: id)
            }

            if isHorizontal {
                row.widthAnchor.constraint(equalToConstant: preferences.design.horizontalTabWidth).isActive = true
            }

            tabStack.addArrangedSubview(row)
        }

        tabScrollView.contentView.scroll(to: .zero)
        tabScrollView.reflectScrolledClipView(tabScrollView.contentView)
    }

    private func tabStateDidChange(_ tab: BrowserTab) {
        if tab.id == activeTabID {
            syncToolbar()
        }

        renderTabs()
    }

    private func showHome(in tab: BrowserTab) {
        tab.loadHomePage(
            searchEngine: preferences.searchEngine,
            theme: preferences.theme,
            colorScheme: preferences.colorScheme,
            design: preferences.design,
            homeBackground: preferences.homeBackground
        )
    }

    private func openSettingsTab() {
        if let existingTab = tabs.first(where: \.isShowingSettings) {
            activeTabID = existingTab.id
            showActiveTab()
            showSettings(in: existingTab)
            renderTabs()
            syncToolbar()
            return
        }

        let tab = makeTab(profile: activeTab?.profile ?? .system)
        tabs.append(tab)
        activeTabID = tab.id
        showActiveTab()
        renderTabs()
        syncToolbar()
        showSettings(in: tab)
    }

    private func showSettings(in tab: BrowserTab) {
        tab.loadSettingsPage(
            preferences: preferences,
            history: BrowserHistoryStore.shared.entries,
            downloads: DownloadHistoryStore.shared.entries,
            performance: PerformanceMonitor.shared.snapshot(
                activeTabs: tabs.count,
                loadingTabs: tabs.filter { $0.webView.isLoading }.count
            ),
            theme: preferences.theme
        )
    }

    private func refreshSettingsTabs() {
        tabs.filter(\.isShowingSettings).forEach { showSettings(in: $0) }
    }

    private func load(_ url: URL, in tab: BrowserTab) {
        if AdBlocker.shouldBlock(url) {
            return
        }

        guard NetworkPolicy.allows(url, profile: tab.profile) else {
            showBlockedURL(url, profile: tab.profile)
            syncToolbar()
            return
        }

        tab.load(url)
    }

    private func handleInternalSearchURL(_ url: URL, in tab: BrowserTab) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            showHome(in: tab)
            return
        }

        let selectedEngine = components.queryItems?
            .first(where: { $0.name == "engine" })?
            .value
            .flatMap(SearchEngine.init(identifier:))

        if let selectedEngine, selectedEngine != preferences.searchEngine {
            preferences.searchEngine = selectedEngine
        }

        guard let query = components.queryItems?.first(where: { $0.name == "q" })?.value,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let targetURL = URLParser.url(from: query, searchEngine: selectedEngine ?? preferences.searchEngine) else {
            showHome(in: tab)
            return
        }

        load(targetURL, in: tab)
    }

    private func handleInternalSettingsURL(_ url: URL, in tab: BrowserTab) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            showSettings(in: tab)
            return
        }

        let action = url.host(percentEncoded: false) ?? ""
        let queryItems = components.queryItems ?? []

        switch action {
        case "update":
            if let identifier = queryItems.first(where: { $0.name == "search" })?.value,
               let searchEngine = SearchEngine(identifier: identifier),
               searchEngine != preferences.searchEngine {
                preferences.searchEngine = searchEngine
            }

            if let identifier = queryItems.first(where: { $0.name == "tabs" })?.value,
               let placement = TabPlacement(identifier: identifier),
               placement != preferences.tabPlacement {
                preferences.tabPlacement = placement
            }

            if let identifier = queryItems.first(where: { $0.name == "theme" })?.value,
               let theme = ThemeMode(identifier: identifier),
               theme != preferences.theme {
                preferences.theme = theme
            }

            if let identifier = queryItems.first(where: { $0.name == "scheme" })?.value,
               let colorScheme = ColorSchemeMode(identifier: identifier),
               colorScheme != preferences.colorScheme {
                preferences.colorScheme = colorScheme
            }

            if let identifier = queryItems.first(where: { $0.name == "design" })?.value,
               let design = DesignMode(identifier: identifier),
               design != preferences.design {
                preferences.design = design
            }

            if let identifier = queryItems.first(where: { $0.name == "home" })?.value,
               let homeBackground = HomeBackgroundMode(identifier: identifier),
               homeBackground != preferences.homeBackground {
                preferences.homeBackground = homeBackground
            }

            showSettings(in: tab)
        case "open":
            guard let rawURL = queryItems.first(where: { $0.name == "url" })?.value,
                  let targetURL = URL(string: rawURL) else {
                showSettings(in: tab)
                return
            }

            load(targetURL, in: tab)
        case "clear-history":
            BrowserHistoryStore.shared.clear()
            refreshSettingsTabs()
        case "clear-downloads":
            DownloadHistoryStore.shared.clear()
            refreshSettingsTabs()
        default:
            showSettings(in: tab)
        }
    }

    private func syncToolbar() {
        guard let tab = activeTab else {
            backButton.isEnabled = false
            forwardButton.isEnabled = false
            reloadButton.isEnabled = false
            addressField.stringValue = ""
            progressIndicator.isHidden = true
            return
        }

        backButton.isEnabled = tab.webView.canGoBack
        forwardButton.isEnabled = tab.webView.canGoForward
        reloadButton.isEnabled = true

        let reloadSymbol = tab.webView.isLoading ? "xmark" : "arrow.clockwise"
        reloadButton.image = NSImage(systemSymbolName: reloadSymbol, accessibilityDescription: tab.webView.isLoading ? "Остановить" : "Обновить")
        reloadButton.toolTip = tab.webView.isLoading ? "Остановить" : "Обновить"

        if !isEditingAddress {
            if tab.isShowingHome {
                addressField.stringValue = ""
            } else if tab.isShowingSettings {
                addressField.stringValue = "northstar://settings"
            } else {
                addressField.stringValue = tab.url?.absoluteString ?? tab.webView.url?.absoluteString ?? ""
            }
        }

        progressIndicator.doubleValue = tab.progress
        progressIndicator.isHidden = tab.isShowingHome || tab.isShowingSettings || !tab.webView.isLoading || tab.progress >= 1

        if let profileIndex = NetworkProfile.allCases.firstIndex(of: tab.profile) {
            networkPopup.selectItem(at: profileIndex)
        }

        if let searchIndex = SearchEngine.allCases.firstIndex(of: preferences.searchEngine) {
            searchEnginePopup.selectItem(at: searchIndex)
        }

        view.window?.title = appName
    }

    private var isEditingAddress: Bool {
        view.window?.firstResponder === addressField.currentEditor()
    }

    private func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }

    private func showBlockedURL(_ url: URL, profile: NetworkProfile) {
        let alert = NSAlert()
        alert.messageText = "Переход заблокирован"
        alert.informativeText = "Режим «\(profile.title)» не разрешает открыть \(url.absoluteString)."
        alert.alertStyle = .warning

        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showLoadError(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }

        let alert = NSAlert(error: error)
        alert.messageText = "Не удалось загрузить страницу"

        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension BrowserViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let tab = tab(for: webView) {
            if !tab.isShowingHome && !tab.isShowingSettings {
                PerformanceMonitor.shared.begin(tabID: tab.id)
            }
            tab.syncFromWebView()
        }
        syncToolbar()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else {
            syncToolbar()
            return
        }

        tab.syncFromWebView()
        if !tab.isShowingHome && !tab.isShowingSettings,
           let currentURL = tab.url ?? webView.url {
            BrowserHistoryStore.shared.record(url: currentURL, title: tab.displayTitle)
            PerformanceMonitor.shared.finish(tabID: tab.id, url: currentURL, title: tab.displayTitle, status: .loaded)
            refreshSettingsTabs()
        }

        syncToolbar()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let tab = tab(for: webView) {
            tab.syncFromWebView()
            if !tab.isShowingHome && !tab.isShowingSettings,
               let currentURL = tab.url ?? webView.url {
                PerformanceMonitor.shared.finish(tabID: tab.id, url: currentURL, title: tab.displayTitle, status: .failed)
                refreshSettingsTabs()
            }
        }
        syncToolbar()
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let tab = tab(for: webView) {
            tab.syncFromWebView()
            if !tab.isShowingHome && !tab.isShowingSettings,
               let currentURL = tab.url ?? webView.url {
                PerformanceMonitor.shared.finish(tabID: tab.id, url: currentURL, title: tab.displayTitle, status: .failed)
                refreshSettingsTabs()
            }
        }
        syncToolbar()
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if url.scheme?.lowercased() == northStarSearchScheme {
            if let tab = tab(for: webView) {
                handleInternalSearchURL(url, in: tab)
            }
            decisionHandler(.cancel)
            return
        }

        if url.scheme?.lowercased() == northStarSettingsScheme {
            if let tab = tab(for: webView) {
                handleInternalSettingsURL(url, in: tab)
            }
            decisionHandler(.cancel)
            return
        }

        if AdBlocker.shouldBlock(url) {
            decisionHandler(.cancel)
            return
        }

        let internalSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob"]
        let scheme = url.scheme?.lowercased()

        guard let scheme, internalSchemes.contains(scheme) else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if let tab = tab(for: webView), !NetworkPolicy.allows(url, profile: tab.profile) {
            if navigationAction.targetFrame?.isMainFrame ?? true {
                showBlockedURL(url, profile: tab.profile)
            }
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let url = navigationResponse.response.url, AdBlocker.shouldBlock(url) {
            decisionHandler(.cancel)
            return
        }

        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

extension BrowserViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if AdBlocker.shouldBlock(url) {
                return nil
            }

            let profile = tab(for: webView)?.profile ?? activeTab?.profile ?? .system
            addTab(profile: profile, url: url, activate: true)
        }

        return nil
    }
}

extension BrowserViewController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let destinationURL = DownloadPath.uniqueDestination(for: suggestedFilename)
        let id = DownloadHistoryStore.shared.start(
            fileName: destinationURL.lastPathComponent,
            sourceURL: response.url,
            destinationURL: destinationURL
        )
        activeDownloads[ObjectIdentifier(download)] = id
        refreshSettingsTabs()
        completionHandler(destinationURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let id = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) {
            DownloadHistoryStore.shared.finish(id: id)
            refreshSettingsTabs()
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let id = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) {
            DownloadHistoryStore.shared.fail(id: id, error: error.localizedDescription)
            refreshSettingsTabs()
        }
    }
}

@MainActor
private final class BrowserTab {
    let id = UUID()
    let profile: NetworkProfile
    let webView: WKWebView
    var onStateChange: ((BrowserTab) -> Void)?

    private(set) var title = appName
    private(set) var url: URL?
    private(set) var progress = 1.0
    private(set) var isShowingHome = true
    private(set) var isShowingSettings = false
    private var observations: [NSKeyValueObservation] = []

    var displayTitle: String {
        if isShowingSettings {
            return settingsTitle
        }

        if isShowingHome {
            return appName
        }

        if !title.isEmpty {
            return title
        }

        if let host = url?.host(percentEncoded: false), !host.isEmpty {
            return host
        }

        return "Новая вкладка"
    }

    init(profile: NetworkProfile) {
        self.profile = profile
        webView = WKWebView(frame: .zero, configuration: profile.makeWebViewConfiguration())
        webView.customUserAgent = BrowserUserAgent.safari
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        bindWebViewState()
    }

    func loadHomePage(searchEngine: SearchEngine, theme: ThemeMode, colorScheme: ColorSchemeMode, design: DesignMode, homeBackground: HomeBackgroundMode) {
        isShowingHome = true
        isShowingSettings = false
        title = appName
        url = nil
        progress = 1
        notifyChanged()
        webView.loadHTMLString(
            HomePage.html(searchEngine: searchEngine, theme: theme, colorScheme: colorScheme, design: design, homeBackground: homeBackground),
            baseURL: nil
        )
    }

    func loadSettingsPage(preferences: AppPreferences, history: [BrowserHistoryEntry], downloads: [DownloadHistoryEntry], performance: PerformanceSnapshot, theme: ThemeMode) {
        isShowingHome = false
        isShowingSettings = true
        title = settingsTitle
        url = nil
        progress = 1
        notifyChanged()
        webView.loadHTMLString(
            SettingsPage.html(preferences: preferences, history: history, downloads: downloads, performance: performance, theme: theme),
            baseURL: nil
        )
    }

    func load(_ url: URL) {
        isShowingHome = false
        isShowingSettings = false
        self.url = url
        title = Self.normalizedTitle(url.host(percentEncoded: false)) ?? "Загрузка"
        progress = 0
        notifyChanged()
        webView.load(URLRequest(url: url))
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations.removeAll()
    }

    func syncFromWebView() {
        if isShowingHome {
            title = appName
            progress = webView.isLoading ? webView.estimatedProgress : 1
        } else if isShowingSettings {
            title = settingsTitle
            progress = webView.isLoading ? webView.estimatedProgress : 1
        } else {
            url = webView.url ?? url
            title = Self.normalizedTitle(webView.title) ?? Self.normalizedTitle(url?.host(percentEncoded: false)) ?? "Новая вкладка"
            progress = webView.estimatedProgress
        }

        notifyChanged()
    }

    private func bindWebViewState() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.progress = webView.estimatedProgress
                    self?.notifyChanged()
                }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !self.isShowingHome && !self.isShowingSettings {
                        self.url = webView.url
                    }
                    self.notifyChanged()
                }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isShowingHome {
                        self.title = appName
                    } else if self.isShowingSettings {
                        self.title = settingsTitle
                    } else {
                        self.title = Self.normalizedTitle(webView.title) ?? self.title
                    }
                    self.notifyChanged()
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.notifyChanged()
                }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.notifyChanged()
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.notifyChanged()
                }
            }
        ]
    }

    private func notifyChanged() {
        onStateChange?(self)
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class AppPreferences {
    static let shared = AppPreferences()
    static let didChangeNotification = Notification.Name("NorthStarPreferencesDidChange")

    var searchEngine: SearchEngine {
        didSet { saveAndNotify(key: Keys.searchEngine, value: searchEngine.rawValue) }
    }

    var tabPlacement: TabPlacement {
        didSet { saveAndNotify(key: Keys.tabPlacement, value: tabPlacement.rawValue) }
    }

    var theme: ThemeMode {
        didSet { saveAndNotify(key: Keys.theme, value: theme.rawValue) }
    }

    var colorScheme: ColorSchemeMode {
        didSet { saveAndNotify(key: Keys.colorScheme, value: colorScheme.rawValue) }
    }

    var design: DesignMode {
        didSet { saveAndNotify(key: Keys.design, value: design.rawValue) }
    }

    var homeBackground: HomeBackgroundMode {
        didSet { saveAndNotify(key: Keys.homeBackground, value: homeBackground.rawValue) }
    }

    private enum Keys {
        static let searchEngine = "searchEngine"
        static let tabPlacement = "tabPlacement"
        static let theme = "theme"
        static let colorScheme = "colorScheme"
        static let design = "design"
        static let homeBackground = "homeBackground"
    }

    private let defaults = UserDefaults.standard

    private init() {
        searchEngine = SearchEngine(rawValue: defaults.integer(forKey: Keys.searchEngine)) ?? .duckDuckGo
        let savedTabPlacement = defaults.object(forKey: Keys.tabPlacement) as? Int
        tabPlacement = savedTabPlacement.flatMap(TabPlacement.init(rawValue:)) ?? .top
        theme = ThemeMode(rawValue: defaults.integer(forKey: Keys.theme)) ?? .system
        colorScheme = ColorSchemeMode(rawValue: defaults.integer(forKey: Keys.colorScheme)) ?? .aurora
        design = DesignMode(rawValue: defaults.integer(forKey: Keys.design)) ?? .balanced
        homeBackground = HomeBackgroundMode(rawValue: defaults.integer(forKey: Keys.homeBackground)) ?? .gradient
    }

    private func saveAndNotify(key: String, value: Int) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

private struct BrowserHistoryEntry: Codable {
    let id: UUID
    var title: String
    var url: String
    var date: Date
}

private final class BrowserHistoryStore {
    static let shared = BrowserHistoryStore()

    private(set) var entries: [BrowserHistoryEntry]
    private let defaults = UserDefaults.standard
    private let key = "browserHistoryEntries"
    private let maximumEntries = 200

    private init() {
        entries = Self.loadEntries(defaults: defaults, key: key)
    }

    func record(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else {
            return
        }

        let urlString = url.absoluteString
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll { $0.url == urlString }
        entries.insert(
            BrowserHistoryEntry(
                id: UUID(),
                title: cleanTitle.isEmpty ? urlString : cleanTitle,
                url: urlString,
                date: Date()
            ),
            at: 0
        )

        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }

        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadEntries(defaults: UserDefaults, key: String) -> [BrowserHistoryEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data) else {
            return []
        }

        return entries
    }
}

private enum DownloadStatus: String, Codable {
    case inProgress
    case completed
    case failed

    var title: String {
        switch self {
        case .inProgress:
            return "Загружается"
        case .completed:
            return "Готово"
        case .failed:
            return "Ошибка"
        }
    }
}

private struct DownloadHistoryEntry: Codable {
    let id: UUID
    var fileName: String
    var sourceURL: String
    var destinationPath: String
    var date: Date
    var status: DownloadStatus
    var errorMessage: String?
}

private final class DownloadHistoryStore {
    static let shared = DownloadHistoryStore()

    private(set) var entries: [DownloadHistoryEntry]
    private let defaults = UserDefaults.standard
    private let key = "downloadHistoryEntries"
    private let maximumEntries = 200

    private init() {
        entries = Self.loadEntries(defaults: defaults, key: key)
    }

    func start(fileName: String, sourceURL: URL?, destinationURL: URL) -> UUID {
        let id = UUID()
        entries.insert(
            DownloadHistoryEntry(
                id: id,
                fileName: fileName,
                sourceURL: sourceURL?.absoluteString ?? "Неизвестный источник",
                destinationPath: destinationURL.path,
                date: Date(),
                status: .inProgress,
                errorMessage: nil
            ),
            at: 0
        )

        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }

        save()
        return id
    }

    func finish(id: UUID) {
        update(id: id) { entry in
            entry.status = .completed
            entry.errorMessage = nil
        }
    }

    func fail(id: UUID, error: String) {
        update(id: id) { entry in
            entry.status = .failed
            entry.errorMessage = error
        }
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func update(id: UUID, mutate: (inout DownloadHistoryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[index])
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadEntries(defaults: UserDefaults, key: String) -> [DownloadHistoryEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([DownloadHistoryEntry].self, from: data) else {
            return []
        }

        return entries
    }
}

private enum PerformanceStatus: String {
    case loaded
    case failed

    var title: String {
        switch self {
        case .loaded:
            return "Готово"
        case .failed:
            return "Ошибка"
        }
    }
}

private struct PerformanceSample {
    let id: UUID
    var title: String
    var url: String
    var date: Date
    var duration: TimeInterval
    var status: PerformanceStatus
}

private struct PerformanceSnapshot {
    var samples: [PerformanceSample]
    var activeTabs: Int
    var loadingTabs: Int
    var residentMemoryMegabytes: Double

    var averageDuration: TimeInterval? {
        let loadedSamples = samples.prefix(20).filter { $0.status == .loaded }
        guard !loadedSamples.isEmpty else { return nil }
        let total = loadedSamples.reduce(0) { $0 + $1.duration }
        return total / Double(loadedSamples.count)
    }
}

@MainActor
private final class PerformanceMonitor {
    static let shared = PerformanceMonitor()

    private var starts: [UUID: Date] = [:]
    private var samples: [PerformanceSample] = []
    private let maximumSamples = 80

    private init() {}

    func begin(tabID: UUID) {
        starts[tabID] = Date()
    }

    func finish(tabID: UUID, url: URL, title: String, status: PerformanceStatus) {
        guard let startedAt = starts.removeValue(forKey: tabID) else { return }
        let duration = max(0.001, Date().timeIntervalSince(startedAt))
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        samples.insert(
            PerformanceSample(
                id: UUID(),
                title: cleanTitle.isEmpty ? url.absoluteString : cleanTitle,
                url: url.absoluteString,
                date: Date(),
                duration: duration,
                status: status
            ),
            at: 0
        )

        if samples.count > maximumSamples {
            samples.removeLast(samples.count - maximumSamples)
        }
    }

    func snapshot(activeTabs: Int, loadingTabs: Int) -> PerformanceSnapshot {
        PerformanceSnapshot(
            samples: samples,
            activeTabs: activeTabs,
            loadingTabs: loadingTabs,
            residentMemoryMegabytes: Self.residentMemoryMegabytes()
        )
    }

    private static func residentMemoryMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }
}

private enum DownloadPath {
    static func uniqueDestination(for suggestedFilename: String) -> URL {
        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let fallbackName = "download-\(Int(Date().timeIntervalSince1970))"
        let sanitizedName = sanitize(suggestedFilename.isEmpty ? fallbackName : suggestedFilename)
        let baseURL = downloadsDirectory.appendingPathComponent(sanitizedName)

        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let fileExtension = baseURL.pathExtension
        let stem = fileExtension.isEmpty
            ? baseURL.lastPathComponent
            : baseURL.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateName = fileExtension.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(fileExtension)"
            let candidateURL = downloadsDirectory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return downloadsDirectory.appendingPathComponent("\(UUID().uuidString)-\(sanitizedName)")
    }

    private static func sanitize(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        let cleaned = filename
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }
}

private enum DateDisplay {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private enum PerformanceDisplay {
    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval else { return "нет данных" }
        return duration(interval)
    }

    static func duration(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return "\(Int((interval * 1000).rounded())) мс"
        }

        return String(format: "%.1f с", interval)
    }

    static func memory(_ megabytes: Double) -> String {
        guard megabytes > 0 else { return "нет данных" }
        if megabytes >= 1024 {
            return String(format: "%.1f ГБ", megabytes / 1024)
        }

        return "\(Int(megabytes.rounded())) МБ"
    }
}

private enum TabPlacement: Int, CaseIterable {
    case left
    case top
    case right
    case bottom

    var title: String {
        switch self {
        case .left:
            return "Слева"
        case .top:
            return "Сверху"
        case .right:
            return "Справа"
        case .bottom:
            return "Снизу"
        }
    }

    var identifier: String {
        switch self {
        case .left:
            return "left"
        case .top:
            return "top"
        case .right:
            return "right"
        case .bottom:
            return "bottom"
        }
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let placement = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = placement
    }

    var isHorizontal: Bool {
        self == .top || self == .bottom
    }
}

private enum ThemeMode: Int, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system:
            return "Системная"
        case .light:
            return "Светлая"
        case .dark:
            return "Тёмная"
        }
    }

    var identifier: String {
        switch self {
        case .system:
            return "system"
        case .light:
            return "light"
        case .dark:
            return "dark"
        }
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let theme = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = theme
    }

    @MainActor
    func apply() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private enum ColorSchemeMode: Int, CaseIterable {
    case aurora
    case graphite
    case ocean
    case forest
    case rose
    case amber

    var title: String {
        switch self {
        case .aurora:
            return "Аврора"
        case .graphite:
            return "Графит"
        case .ocean:
            return "Океан"
        case .forest:
            return "Лес"
        case .rose:
            return "Роза"
        case .amber:
            return "Янтарь"
        }
    }

    var identifier: String {
        switch self {
        case .aurora:
            return "aurora"
        case .graphite:
            return "graphite"
        case .ocean:
            return "ocean"
        case .forest:
            return "forest"
        case .rose:
            return "rose"
        case .amber:
            return "amber"
        }
    }

    var accent: String {
        switch self {
        case .aurora:
            return "#6ee7c7"
        case .graphite:
            return "#aeb7c2"
        case .ocean:
            return "#38bdf8"
        case .forest:
            return "#86efac"
        case .rose:
            return "#fb7185"
        case .amber:
            return "#f59e0b"
        }
    }

    var accentTwo: String {
        switch self {
        case .aurora:
            return "#8dc7ff"
        case .graphite:
            return "#e5e7eb"
        case .ocean:
            return "#22d3ee"
        case .forest:
            return "#34d399"
        case .rose:
            return "#f0abfc"
        case .amber:
            return "#fde68a"
        }
    }

    var lightBackground: String {
        switch self {
        case .aurora:
            return "#eff6f7"
        case .graphite:
            return "#f2f4f6"
        case .ocean:
            return "#edf7fb"
        case .forest:
            return "#eff8f0"
        case .rose:
            return "#fbf1f5"
        case .amber:
            return "#fbf5e8"
        }
    }

    var lightPanelStrong: String {
        switch self {
        case .aurora:
            return "#dbe8e8"
        case .graphite:
            return "#dfe4e9"
        case .ocean:
            return "#d8eef7"
        case .forest:
            return "#dceee0"
        case .rose:
            return "#f2dce5"
        case .amber:
            return "#f0e4c8"
        }
    }

    var darkBackground: String {
        switch self {
        case .aurora:
            return "#071013"
        case .graphite:
            return "#0d0f12"
        case .ocean:
            return "#06111b"
        case .forest:
            return "#07130d"
        case .rose:
            return "#150910"
        case .amber:
            return "#151006"
        }
    }

    var darkPanelStrong: String {
        switch self {
        case .aurora:
            return "#17252a"
        case .graphite:
            return "#20242a"
        case .ocean:
            return "#102a36"
        case .forest:
            return "#152b20"
        case .rose:
            return "#2d1722"
        case .amber:
            return "#2c2412"
        }
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let scheme = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = scheme
    }
}

private enum DesignMode: Int, CaseIterable {
    case balanced
    case compact
    case spacious
    case focus

    var title: String {
        switch self {
        case .balanced:
            return "Сбалансированный"
        case .compact:
            return "Компактный"
        case .spacious:
            return "Просторный"
        case .focus:
            return "Фокус"
        }
    }

    var identifier: String {
        switch self {
        case .balanced:
            return "balanced"
        case .compact:
            return "compact"
        case .spacious:
            return "spacious"
        case .focus:
            return "focus"
        }
    }

    var toolbarHeight: CGFloat {
        switch self {
        case .balanced:
            return 56
        case .compact:
            return 50
        case .spacious:
            return 64
        case .focus:
            return 54
        }
    }

    var verticalTabBarWidth: CGFloat {
        switch self {
        case .balanced:
            return 244
        case .compact:
            return 220
        case .spacious:
            return 268
        case .focus:
            return 228
        }
    }

    var horizontalTabBarHeight: CGFloat {
        switch self {
        case .balanced:
            return 40
        case .compact:
            return 36
        case .spacious:
            return 44
        case .focus:
            return 38
        }
    }

    var horizontalTabHeaderWidth: CGFloat {
        switch self {
        case .balanced:
            return 42
        case .compact:
            return 38
        case .spacious:
            return 46
        case .focus:
            return 40
        }
    }

    var verticalTabRowHeight: CGFloat {
        switch self {
        case .balanced:
            return 38
        case .compact:
            return 34
        case .spacious:
            return 42
        case .focus:
            return 36
        }
    }

    var horizontalTabRowHeight: CGFloat {
        switch self {
        case .balanced:
            return 30
        case .compact:
            return 28
        case .spacious:
            return 32
        case .focus:
            return 29
        }
    }

    var horizontalTabWidth: CGFloat {
        switch self {
        case .balanced:
            return 188
        case .compact:
            return 158
        case .spacious:
            return 210
        case .focus:
            return 172
        }
    }

    var tabSpacing: CGFloat {
        switch self {
        case .balanced:
            return 4
        case .compact:
            return 3
        case .spacious:
            return 6
        case .focus:
            return 4
        }
    }

    var horizontalTabInset: CGFloat {
        switch self {
        case .balanced:
            return 4
        case .compact:
            return 3
        case .spacious:
            return 5
        case .focus:
            return 4
        }
    }

    var horizontalTabSpacing: CGFloat {
        switch self {
        case .balanced:
            return 2
        case .compact:
            return 1
        case .spacious:
            return 3
        case .focus:
            return 2
        }
    }

    var rowCornerRadius: CGFloat {
        switch self {
        case .balanced:
            return 7
        case .compact:
            return 6
        case .spacious:
            return 8
        case .focus:
            return 6
        }
    }

    var pageWidth: String {
        switch self {
        case .balanced:
            return "860px"
        case .compact:
            return "760px"
        case .spacious:
            return "980px"
        case .focus:
            return "780px"
        }
    }

    var settingsWidth: String {
        switch self {
        case .balanced:
            return "1120px"
        case .compact:
            return "980px"
        case .spacious:
            return "1240px"
        case .focus:
            return "1040px"
        }
    }

    var radius: String {
        switch self {
        case .balanced:
            return "14px"
        case .compact:
            return "8px"
        case .spacious:
            return "18px"
        case .focus:
            return "6px"
        }
    }

    var gap: String {
        switch self {
        case .balanced:
            return "22px"
        case .compact:
            return "14px"
        case .spacious:
            return "30px"
        case .focus:
            return "18px"
        }
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let design = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = design
    }
}

private enum HomeBackgroundMode: Int, CaseIterable {
    case gradient
    case solid
    case grid
    case glow
    case glass

    var title: String {
        switch self {
        case .gradient:
            return "Мягкий градиент"
        case .solid:
            return "Однотонный"
        case .grid:
            return "Тонкая сетка"
        case .glow:
            return "Свечение"
        case .glass:
            return "Стекло"
        }
    }

    var identifier: String {
        switch self {
        case .gradient:
            return "gradient"
        case .solid:
            return "solid"
        case .grid:
            return "grid"
        case .glow:
            return "glow"
        case .glass:
            return "glass"
        }
    }

    var backgroundCSS: String {
        switch self {
        case .gradient:
            return "linear-gradient(120deg, var(--bg) 0%, var(--panel-strong) 54%, var(--bg) 100%)"
        case .solid:
            return "var(--bg)"
        case .grid:
            return "linear-gradient(120deg, var(--bg), var(--panel-strong))"
        case .glow:
            return "radial-gradient(circle at 28% 28%, color-mix(in srgb, var(--accent) 28%, transparent), transparent 31%), radial-gradient(circle at 74% 62%, color-mix(in srgb, var(--accent-2) 24%, transparent), transparent 34%), linear-gradient(140deg, var(--bg), var(--panel-strong))"
        case .glass:
            return "linear-gradient(135deg, color-mix(in srgb, var(--bg) 82%, var(--accent) 10%), color-mix(in srgb, var(--panel-strong) 86%, var(--accent-2) 12%))"
        }
    }

    var overlayCSS: String {
        switch self {
        case .gradient, .solid:
            return "none"
        case .grid:
            return "linear-gradient(var(--line) 1px, transparent 1px), linear-gradient(90deg, var(--line) 1px, transparent 1px)"
        case .glow:
            return "radial-gradient(circle at 50% 50%, transparent, color-mix(in srgb, var(--bg) 78%, transparent) 72%)"
        case .glass:
            return "linear-gradient(115deg, rgba(255,255,255,0.13), transparent 32%, rgba(255,255,255,0.08) 62%, transparent)"
        }
    }

    var overlayOpacity: String {
        switch self {
        case .gradient, .solid:
            return "0"
        case .grid:
            return "0.24"
        case .glow:
            return "0.62"
        case .glass:
            return "0.42"
        }
    }

    var overlaySize: String {
        switch self {
        case .grid:
            return "42px 42px"
        default:
            return "auto"
        }
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let background = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = background
    }
}

private enum SearchEngine: Int, CaseIterable {
    case duckDuckGo
    case google
    case yandex
    case brave
    case bing
    case ecosia
    case startpage

    var title: String {
        switch self {
        case .duckDuckGo:
            return "DuckDuckGo"
        case .google:
            return "Google"
        case .yandex:
            return "Yandex"
        case .brave:
            return "Brave"
        case .bing:
            return "Bing"
        case .ecosia:
            return "Ecosia"
        case .startpage:
            return "Startpage"
        }
    }

    var identifier: String {
        switch self {
        case .duckDuckGo:
            return "duckduckgo"
        case .google:
            return "google"
        case .yandex:
            return "yandex"
        case .brave:
            return "brave"
        case .bing:
            return "bing"
        case .ecosia:
            return "ecosia"
        case .startpage:
            return "startpage"
        }
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let engine = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = engine
    }

    func searchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        switch self {
        case .duckDuckGo:
            return URL(string: "https://duckduckgo.com/?q=\(encoded)")
        case .google:
            return URL(string: "https://www.google.com/search?q=\(encoded)")
        case .yandex:
            return URL(string: "https://yandex.com/search/?text=\(encoded)")
        case .brave:
            return URL(string: "https://search.brave.com/search?q=\(encoded)")
        case .bing:
            return URL(string: "https://www.bing.com/search?q=\(encoded)")
        case .ecosia:
            return URL(string: "https://www.ecosia.org/search?q=\(encoded)")
        case .startpage:
            return URL(string: "https://www.startpage.com/sp/search?query=\(encoded)")
        }
    }
}

private struct ChromePalette {
    let window: NSColor
    let webBackground: NSColor
    let brand: NSColor
    let secondaryText: NSColor

    init(theme: ThemeMode, colorScheme: ColorSchemeMode) {
        switch theme {
        case .light:
            window = NSColor(hex: colorScheme.lightBackground) ?? NSColor(red: 0.95, green: 0.97, blue: 0.98, alpha: 1)
            webBackground = NSColor(hex: colorScheme.lightPanelStrong) ?? NSColor(red: 0.98, green: 0.99, blue: 1, alpha: 1)
            brand = NSColor(red: 0.08, green: 0.13, blue: 0.18, alpha: 1)
            secondaryText = NSColor(red: 0.36, green: 0.43, blue: 0.48, alpha: 1)
        case .dark:
            window = NSColor(hex: colorScheme.darkBackground) ?? NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
            webBackground = NSColor(hex: colorScheme.darkPanelStrong) ?? NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)
            brand = NSColor(red: 0.92, green: 0.98, blue: 1, alpha: 1)
            secondaryText = NSColor(red: 0.66, green: 0.72, blue: 0.75, alpha: 1)
        case .system:
            window = .windowBackgroundColor
            webBackground = .textBackgroundColor
            brand = .labelColor
            secondaryText = .secondaryLabelColor
        }
    }
}

private enum NetworkProfile: Int, CaseIterable, Equatable {
    case system
    case privateBrowsing
    case tor
    case localhost

    var title: String {
        switch self {
        case .system:
            return "Система"
        case .privateBrowsing:
            return "Приватно"
        case .tor:
            return "Tor SOCKS"
        case .localhost:
            return "Локально"
        }
    }

    var detail: String {
        switch self {
        case .system:
            return "Обычная сеть"
        case .privateBrowsing:
            return "Без сохранения"
        case .tor:
            return "127.0.0.1:9050"
        case .localhost:
            return "Только локально"
        }
    }

    @MainActor
    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        AdBlocker.install(in: configuration)

        switch self {
        case .system:
            configuration.websiteDataStore = .default()
        case .privateBrowsing, .localhost:
            configuration.websiteDataStore = .nonPersistent()
        case .tor:
            let dataStore = WKWebsiteDataStore.nonPersistent()
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: 9050))
            proxy.allowFailover = false
            dataStore.proxyConfigurations = [proxy]
            configuration.websiteDataStore = dataStore
        }

        return configuration
    }
}

private enum BrowserUserAgent {
    static let applicationName = "Version/18.5 Safari/605.1.15"
    static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(applicationName)"
}

private enum AdBlocker {
    private static let contentRuleIdentifier = "NorthStarAggressiveAdBlocker.v1"

    private static let blockedHostSuffixes = [
        "2mdn.net",
        "adform.net",
        "adnxs.com",
        "adsafeprotected.com",
        "adsrvr.org",
        "adservice.google.com",
        "adservice.google.pl",
        "advertising.com",
        "amazon-adsystem.com",
        "appnexus.com",
        "bidswitch.net",
        "casalemedia.com",
        "consensu.org",
        "criteo.com",
        "criteo.net",
        "doubleclick.net",
        "googlesyndication.com",
        "googletagmanager.com",
        "googletagservices.com",
        "google-analytics.com",
        "imasdk.googleapis.com",
        "moatads.com",
        "nitropay.com",
        "openx.net",
        "outbrain.com",
        "pubmatic.com",
        "quantserve.com",
        "rubiconproject.com",
        "scorecardresearch.com",
        "smartadserver.com",
        "taboola.com",
        "yieldmo.com"
    ]

    private static let blockedURLFragments = [
        "/adserver/",
        "/ads/",
        "/advert/",
        "/banners/",
        "/gampad/",
        "/pagead/",
        "adservice.",
        "adsystem",
        "googleads",
        "prebid",
        "vast?"
    ]

    static func shouldBlock(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return false
        }

        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        if blockedHostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return true
        }

        let absoluteString = url.absoluteString.lowercased()
        return blockedURLFragments.contains { absoluteString.contains($0) }
    }

    @MainActor
    static func install(in configuration: WKWebViewConfiguration) {
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController = userContentController

        guard let store = WKContentRuleListStore.default() else {
            return
        }

        store.lookUpContentRuleList(forIdentifier: contentRuleIdentifier) { existingList, _ in
            if let existingList {
                DispatchQueue.main.async {
                    userContentController.add(existingList)
                }
                return
            }

            store.compileContentRuleList(forIdentifier: contentRuleIdentifier, encodedContentRuleList: contentRules) { compiledList, _ in
                guard let compiledList else { return }
                DispatchQueue.main.async {
                    userContentController.add(compiledList)
                }
            }
        }
    }

    private static let contentRules = """
    [
      { "trigger": { "url-filter": ".*2mdn\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adform\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adnxs\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adsafeprotected\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adsrvr\\\\.org.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adservice\\\\.google\\\\..*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*advertising\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*amazon-adsystem\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*appnexus\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*bidswitch\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*casalemedia\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*consensu\\\\.org.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*criteo\\\\.(com|net).*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*doubleclick\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*googlesyndication\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*googletag(manager|services)\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*google-analytics\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*imasdk\\\\.googleapis\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*moatads\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*nitropay\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*openx\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*outbrain\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*pubmatic\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*quantserve\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*rubiconproject\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*scorecardresearch\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*smartadserver\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*taboola\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*yieldmo\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*(/adserver/|/ads/|/advert/|/banners/|/gampad/|/pagead/|googleads|prebid|vast\\\\?).*" }, "action": { "type": "block" } }
    ]
    """

    private static let script = """
    (() => {
      const selectors = [
        ".adsbygoogle",
        ".ad-banner",
        ".ad-container",
        ".ad-slot",
        ".ad_unit",
        ".adbox",
        ".adframe",
        ".adslot",
        ".advert",
        ".advertisement",
        ".banner-ad",
        ".fc-consent-root",
        ".google-auto-placed",
        ".nitro-ad",
        ".nitro-ad-container",
        ".qc-cmp2-container",
        ".sp_message_container",
        "#onetrust-consent-sdk",
        "[aria-label='Advertisement']",
        "[class*=' ad-']",
        "[class*=' ads']",
        "[class*='advert']",
        "[class*='nitro']",
        "[data-ad]",
        "[data-ad-client]",
        "[data-ad-slot]",
        "[data-google-query-id]",
        "[id*='ad-']",
        "[id*='ads']",
        "[id*='advert']",
        "[id*='nitro']",
        "iframe[src*='2mdn.net']",
        "iframe[src*='adservice.google']",
        "iframe[src*='doubleclick.net']",
        "iframe[src*='googlesyndication.com']",
        "iframe[src*='imasdk.googleapis.com']",
        "iframe[src*='nitropay.com']",
        "ins.adsbygoogle"
      ];
      const blockedFragments = [
        "2mdn.net",
        "adform.net",
        "adnxs.com",
        "adsafeprotected.com",
        "adsrvr.org",
        "adservice.google.",
        "advertising.com",
        "amazon-adsystem.com",
        "appnexus.com",
        "bidswitch.net",
        "casalemedia.com",
        "consensu.org",
        "criteo.com",
        "criteo.net",
        "doubleclick.net",
        "googlesyndication.com",
        "googletagmanager.com",
        "googletagservices.com",
        "google-analytics.com",
        "googleads",
        "imasdk.googleapis.com",
        "moatads.com",
        "nitropay.com",
        "openx.net",
        "outbrain.com",
        "pagead/",
        "prebid",
        "pubmatic.com",
        "rubiconproject.com",
        "scorecardresearch.com",
        "smartadserver.com",
        "taboola.com",
        "yieldmo.com"
      ];
      const shouldBlock = value => {
        const text = String(value || "").toLowerCase();
        return blockedFragments.some(fragment => text.includes(fragment));
      };
      const selectorText = selectors.join(",");
      const ensureStyle = () => {
        if (document.getElementById("northstar-adblock-style")) return;
        const style = document.createElement("style");
        style.id = "northstar-adblock-style";
        style.textContent = selectorText + "{display:none!important;visibility:hidden!important;opacity:0!important;pointer-events:none!important;max-height:0!important;max-width:0!important;overflow:hidden!important;}";
        (document.head || document.documentElement).appendChild(style);
      };
      const removeMatches = () => {
        ensureStyle();
        try {
          document.querySelectorAll(selectorText).forEach(element => element.remove());
        } catch (_) {}
        document.querySelectorAll("iframe,img,script,link,source,video,ins").forEach(element => {
          const url = element.currentSrc || element.src || element.href || "";
          if (shouldBlock(url)) element.remove();
        });
      };
      const start = () => {
        removeMatches();
        const observer = new MutationObserver(() => removeMatches());
        observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["src", "href", "class", "id"] });
      };
      if (document.documentElement) {
        start();
      } else {
        document.addEventListener("DOMContentLoaded", start, { once: true });
      }
    })();
    """
}

private enum NetworkPolicy {
    static func allows(_ url: URL, profile: NetworkProfile) -> Bool {
        guard profile == .localhost else { return true }

        guard let scheme = url.scheme?.lowercased() else { return false }

        if ["about", "file", "data", "blob"].contains(scheme) {
            return true
        }

        if [northStarSearchScheme, northStarSettingsScheme].contains(scheme) {
            return true
        }

        guard ["http", "https"].contains(scheme) else {
            return false
        }

        guard let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }

        return host == "localhost"
            || host == "::1"
            || host == "[::1]"
            || host.hasPrefix("127.")
            || host == "0.0.0.0"
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class TabRowView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let indicatorView = NSView()
    private let titleField = NSTextField(labelWithString: "Новая вкладка")
    private let detailField = NSTextField(labelWithString: "")
    private let closeButton = IconButton(symbolName: "xmark", tooltip: "Закрыть вкладку", width: 20, height: 20)
    private var isActive = false
    private var isHovered = false
    private var isHorizontalLayout = false
    private var heightConstraint: NSLayoutConstraint?
    private var titleTopConstraint: NSLayoutConstraint?
    private var titleCenterYConstraint: NSLayoutConstraint?
    private var titleLeadingConstraint: NSLayoutConstraint?
    private var indicatorWidthConstraint: NSLayoutConstraint?
    private var trackingAreaReference: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.wantsLayer = true
        indicatorView.layer?.cornerRadius = 1.5

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 12.8, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail

        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))

        addSubview(indicatorView)
        addSubview(titleField)
        addSubview(detailField)
        addSubview(closeButton)

        let height = heightAnchor.constraint(equalToConstant: 58)
        let titleTop = titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        let titleCenterY = titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        let titleLeading = titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18)
        let indicatorWidth = indicatorView.widthAnchor.constraint(equalToConstant: 3)
        heightConstraint = height
        titleTopConstraint = titleTop
        titleCenterYConstraint = titleCenterY
        titleLeadingConstraint = titleLeading
        indicatorWidthConstraint = indicatorWidth

        NSLayoutConstraint.activate([
            height,

            indicatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            indicatorView.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            indicatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            indicatorWidth,

            titleTop,
            titleLeading,
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),

            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7)
        ])
        titleCenterY.isActive = false

        updateStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(title: String, detail: String, isActive: Bool, isHorizontal: Bool, design: DesignMode) {
        titleField.stringValue = title
        detailField.stringValue = detail
        detailField.isHidden = true
        self.isActive = isActive
        isHorizontalLayout = isHorizontal
        layer?.cornerRadius = design.rowCornerRadius
        heightConstraint?.constant = isHorizontal ? design.horizontalTabRowHeight : design.verticalTabRowHeight
        indicatorView.isHidden = isHorizontal
        indicatorWidthConstraint?.constant = isHorizontal ? 0 : 3
        titleLeadingConstraint?.constant = isHorizontal ? 12 : 18
        titleTopConstraint?.isActive = false
        titleCenterYConstraint?.isActive = true
        updateStyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        trackingAreaReference = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateStyle()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closePressed(_ sender: Any?) {
        onClose?()
    }

    private func updateStyle() {
        let accent = NSColor.controlAccentColor
        titleField.font = .systemFont(ofSize: isHorizontalLayout ? 12.2 : 12.8, weight: isActive ? .semibold : .medium)
        titleField.textColor = isActive ? .labelColor : .secondaryLabelColor
        detailField.textColor = .secondaryLabelColor

        if isHorizontalLayout {
            let activeColor = NSColor.controlBackgroundColor.withAlphaComponent(0.52)
            let hoverColor = NSColor.controlBackgroundColor.withAlphaComponent(0.2)
            layer?.backgroundColor = isActive
                ? activeColor.cgColor
                : (isHovered ? hoverColor.cgColor : NSColor.clear.cgColor)
            layer?.borderWidth = isActive ? 0.5 : 0
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor
        } else {
            let activeColor = accent.withAlphaComponent(0.11)
            let hoverColor = NSColor.controlBackgroundColor.withAlphaComponent(0.22)
            layer?.backgroundColor = isActive
                ? activeColor.cgColor
                : (isHovered ? hoverColor.cgColor : NSColor.clear.cgColor)
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
            indicatorView.layer?.backgroundColor = isActive
                ? accent.cgColor
                : NSColor.clear.cgColor
        }

        closeButton.alphaValue = isActive || isHovered ? 0.62 : 0
        closeButton.contentTintColor = isActive ? .secondaryLabelColor : .tertiaryLabelColor
    }
}

private final class IconButton: NSButton {
    init(symbolName: String, tooltip: String, width: CGFloat = 32, height: CGFloat = 30) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        imagePosition = .imageOnly
        bezelStyle = .texturedRounded
        isBordered = true
        toolTip = tooltip

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private enum URLParser {
    static func url(from input: String, searchEngine: SearchEngine) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.lowercased()
        if normalized == "northstar://settings"
            || normalized == "\(northStarSettingsScheme)://home"
            || normalized == "settings"
            || normalized == "настройки" {
            return URL(string: "\(northStarSettingsScheme)://home")
        }

        if let directURL = URL(string: trimmed),
           let scheme = directURL.scheme?.lowercased(),
           ["http", "https", "file"].contains(scheme) {
            return directURL
        }

        if looksLikeHost(trimmed) {
            return URL(string: "\(defaultScheme(for: trimmed))://\(trimmed)")
        }

        return searchEngine.searchURL(for: trimmed)
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return false
        }

        return text == "localhost"
            || text.hasPrefix("localhost:")
            || text.hasPrefix("127.")
            || text.hasPrefix("0.0.0.0")
            || text.hasPrefix("[::1]")
            || text.contains(".")
    }

    private static func defaultScheme(for host: String) -> String {
        if host == "localhost"
            || host.hasPrefix("localhost:")
            || host.hasPrefix("127.")
            || host.hasPrefix("0.0.0.0")
            || host.hasPrefix("[::1]") {
            return "http"
        }

        return "https"
    }
}

private enum HomePage {
    static func html(searchEngine: SearchEngine, theme: ThemeMode, colorScheme: ColorSchemeMode, design: DesignMode, homeBackground: HomeBackgroundMode) -> String {
        let palette = HomePalette(theme: theme, colorScheme: colorScheme, design: design)
        let engine = searchEngine.title.htmlEscaped
        let engineOptions = SearchEngine.allCases.map { option in
            let selected = option == searchEngine ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()

        return """
        <!doctype html>
        <html lang="ru">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(appName)</title>
          <style>
            :root {
              color-scheme: \(palette.colorScheme);
              --bg: \(palette.background);
              --panel: \(palette.panel);
              --panel-strong: \(palette.panelStrong);
              --text: \(palette.text);
              --muted: \(palette.muted);
              --line: \(palette.line);
              --accent: \(palette.accent);
              --accent-2: \(palette.accentTwo);
              --shadow: \(palette.shadow);
              --radius: \(palette.radius);
              --gap: \(palette.gap);
              --page-width: \(palette.pageWidth);
              --home-bg: \(homeBackground.backgroundCSS);
              --home-overlay: \(homeBackground.overlayCSS);
              --home-overlay-opacity: \(homeBackground.overlayOpacity);
              --home-overlay-size: \(homeBackground.overlaySize);
            }
            * { box-sizing: border-box; }
            html, body { margin: 0; min-height: 100%; }
            body {
              min-height: 100vh;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif;
              color: var(--text);
              background: var(--home-bg);
              display: grid;
              place-items: center;
              overflow: hidden;
            }
            body::before {
              content: "";
              position: fixed;
              inset: 0;
              pointer-events: none;
              background: var(--home-overlay);
              background-size: var(--home-overlay-size);
              opacity: var(--home-overlay-opacity);
              mask-image: radial-gradient(circle at center, black, transparent 78%);
            }
            main {
              width: min(var(--page-width), calc(100vw - 48px));
              display: grid;
              gap: var(--gap);
              position: relative;
              z-index: 1;
            }
            .mast {
              display: grid;
              gap: 12px;
              text-align: center;
            }
            h1 {
              margin: 0;
              font-size: clamp(54px, 9vw, 108px);
              line-height: 0.94;
              letter-spacing: 0;
              font-weight: 800;
            }
            .line {
              width: min(360px, 60vw);
              height: 3px;
              margin: 0 auto;
              border-radius: 999px;
              background: linear-gradient(90deg, var(--accent), var(--accent-2));
            }
            .sub {
              margin: 0;
              color: var(--muted);
              font-size: 17px;
              line-height: 1.5;
            }
            .search {
              display: grid;
              grid-template-columns: minmax(180px, 1fr) 176px auto;
              gap: 10px;
              padding: 12px;
              background: var(--panel);
              border: 1px solid var(--line);
              border-radius: calc(var(--radius) + 4px);
              box-shadow: 0 26px 70px var(--shadow);
            }
            input {
              width: 100%;
              min-width: 0;
              border: 0;
              outline: 0;
              border-radius: var(--radius);
              padding: 16px 18px;
              font-size: 17px;
              color: var(--text);
              background: transparent;
            }
            input::placeholder { color: var(--muted); }
            select {
              width: 100%;
              min-width: 0;
              border: 1px solid var(--line);
              outline: 0;
              border-radius: var(--radius);
              padding: 0 14px;
              font-size: 15px;
              font-weight: 650;
              color: var(--text);
              background: color-mix(in srgb, var(--panel) 72%, transparent);
            }
            button {
              border: 0;
              border-radius: var(--radius);
              padding: 0 22px;
              min-width: 112px;
              font-size: 15px;
              font-weight: 700;
              color: #071015;
              background: linear-gradient(135deg, var(--accent), var(--accent-2));
              cursor: pointer;
            }
            .quick {
              display: grid;
              grid-template-columns: repeat(4, minmax(0, 1fr));
              gap: 10px;
            }
            .quick a {
              color: var(--text);
              text-decoration: none;
              padding: 14px 15px;
              border: 1px solid var(--line);
              border-radius: var(--radius);
              background: color-mix(in srgb, var(--panel) 74%, transparent);
              font-size: 14px;
              font-weight: 650;
              text-align: center;
            }
            .engine {
              color: var(--muted);
              font-size: 13px;
              text-align: center;
            }
            @media (max-width: 680px) {
              .search { grid-template-columns: 1fr; }
              select { height: 46px; }
              button { height: 46px; }
              .quick { grid-template-columns: repeat(2, minmax(0, 1fr)); }
            }
          </style>
        </head>
        <body>
          <main>
            <section class="mast" aria-label="NorthStar">
              <h1>\(appName)</h1>
              <div class="line"></div>
              <p class="sub">Ищите, открывайте сайты или начинайте с привычных мест.</p>
            </section>
            <form class="search" id="searchForm">
              <input id="query" name="q" autofocus autocomplete="off" placeholder="Поиск или адрес сайта">
              <select id="engine" name="engine" aria-label="Поисковая система">
                \(engineOptions)
              </select>
              <button type="submit">Открыть</button>
            </form>
            <div class="engine">Текущая поисковая система: \(engine)</div>
            <nav class="quick" aria-label="Быстрые ссылки">
              <a href="https://github.com">GitHub</a>
              <a href="https://news.ycombinator.com">Hacker News</a>
              <a href="https://developer.apple.com">Apple Dev</a>
              <a href="http://localhost:3000">Локальный сервер</a>
            </nav>
          </main>
          <script>
            const form = document.getElementById("searchForm");
            const query = document.getElementById("query");
            const engine = document.getElementById("engine");
            engine.addEventListener("change", () => {
              window.location.href = "\(northStarSearchScheme)://engine?engine=" + encodeURIComponent(engine.value);
            });
            form.addEventListener("submit", event => {
              event.preventDefault();
              const value = query.value.trim();
              if (!value) return;
              window.location.href = "\(northStarSearchScheme)://search?q=" + encodeURIComponent(value) + "&engine=" + encodeURIComponent(engine.value);
            });
          </script>
        </body>
        </html>
        """
    }
}

private enum SettingsPage {
    static func html(preferences: AppPreferences, history: [BrowserHistoryEntry], downloads: [DownloadHistoryEntry], performance: PerformanceSnapshot, theme: ThemeMode) -> String {
        let palette = HomePalette(theme: theme, colorScheme: preferences.colorScheme, design: preferences.design)
        let searchOptions = SearchEngine.allCases.map { option in
            let selected = option == preferences.searchEngine ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let tabOptions = TabPlacement.allCases.map { option in
            let selected = option == preferences.tabPlacement ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let themeOptions = ThemeMode.allCases.map { option in
            let selected = option == preferences.theme ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let schemeOptions = ColorSchemeMode.allCases.map { option in
            let selected = option == preferences.colorScheme ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let designOptions = DesignMode.allCases.map { option in
            let selected = option == preferences.design ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let homeOptions = HomeBackgroundMode.allCases.map { option in
            let selected = option == preferences.homeBackground ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()

        let historyMarkup = history.prefix(60).map { entry in
            let openURL = "\(northStarSettingsScheme)://open?url=\(entry.url.urlQueryEscaped)"
            return """
            <a class="list-row" href="\(openURL)">
              <span class="row-main">
                <strong>\(entry.title.htmlEscaped)</strong>
                <small>\(entry.url.htmlEscaped)</small>
              </span>
              <time>\(DateDisplay.string(from: entry.date).htmlEscaped)</time>
            </a>
            """
        }.joined()

        let downloadsMarkup = downloads.prefix(60).map { entry in
            let error = entry.errorMessage.map { "<small>\($0.htmlEscaped)</small>" } ?? "<small>\(entry.destinationPath.htmlEscaped)</small>"
            return """
            <div class="list-row">
              <span class="row-main">
                <strong>\(entry.fileName.htmlEscaped)</strong>
                \(error)
              </span>
              <span class="status \(entry.status.rawValue)">\(entry.status.title.htmlEscaped)</span>
            </div>
            """
        }.joined()

        let performanceMarkup = performance.samples.prefix(30).map { sample in
            return """
            <div class="list-row">
              <span class="row-main">
                <strong>\(sample.title.htmlEscaped)</strong>
                <small>\(sample.url.htmlEscaped)</small>
              </span>
              <span class="row-meta">
                <span class="status \(sample.status.rawValue)">\(sample.status.title.htmlEscaped)</span>
                <strong class="duration">\(PerformanceDisplay.duration(sample.duration).htmlEscaped)</strong>
                <time>\(DateDisplay.string(from: sample.date).htmlEscaped)</time>
              </span>
            </div>
            """
        }.joined()

        return """
        <!doctype html>
        <html lang="ru">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(settingsTitle)</title>
          <style>
            :root {
              color-scheme: \(palette.colorScheme);
              --bg: \(palette.background);
              --panel: \(palette.panel);
              --panel-strong: \(palette.panelStrong);
              --text: \(palette.text);
              --muted: \(palette.muted);
              --line: \(palette.line);
              --accent: \(palette.accent);
              --accent-2: \(palette.accentTwo);
              --shadow: \(palette.shadow);
              --radius: \(palette.radius);
              --gap: \(palette.gap);
              --settings-width: \(palette.settingsWidth);
            }
            * { box-sizing: border-box; }
            html, body { margin: 0; min-height: 100%; }
            body {
              min-height: 100vh;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif;
              color: var(--text);
              background: linear-gradient(120deg, var(--bg), var(--panel-strong));
            }
            main {
              width: min(var(--settings-width), calc(100vw - 56px));
              margin: 0 auto;
              padding: 40px 0 56px;
              display: grid;
              gap: var(--gap);
            }
            header {
              display: flex;
              justify-content: space-between;
              gap: 18px;
              align-items: end;
              border-bottom: 1px solid var(--line);
              padding-bottom: 18px;
            }
            h1, h2 { margin: 0; letter-spacing: 0; }
            h1 { font-size: 38px; line-height: 1; }
            h2 { font-size: 19px; }
            .muted { color: var(--muted); font-size: 14px; margin: 8px 0 0; }
            .settings-grid {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
              gap: 12px;
            }
            label, .section-head {
              display: grid;
              gap: 8px;
            }
            label span {
              color: var(--muted);
              font-size: 12px;
              font-weight: 700;
              text-transform: uppercase;
            }
            select {
              width: 100%;
              min-width: 0;
              min-height: 38px;
              border-radius: var(--radius);
              border: 1px solid var(--line);
              color: var(--text);
              background: var(--panel);
              padding: 0 12px;
              font-size: 14px;
              font-weight: 650;
            }
            section {
              display: grid;
              gap: 12px;
            }
            .section-head {
              grid-template-columns: minmax(0, 1fr) auto;
              align-items: center;
            }
            .list {
              display: grid;
              gap: 8px;
            }
            .list-row {
              min-height: 58px;
              display: grid;
              grid-template-columns: minmax(0, 1fr) auto;
              gap: 18px;
              align-items: center;
              color: var(--text);
              text-decoration: none;
              border: 1px solid var(--line);
              border-radius: var(--radius);
              background: var(--panel);
              padding: 12px 14px;
              box-shadow: 0 14px 34px var(--shadow);
            }
            .list-row:hover {
              border-color: color-mix(in srgb, var(--accent) 60%, var(--line));
            }
            .row-main {
              min-width: 0;
              display: grid;
              gap: 4px;
            }
            strong, small, time {
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            strong { font-size: 14px; }
            small, time { color: var(--muted); font-size: 12px; }
            .empty {
              color: var(--muted);
              border: 1px dashed var(--line);
              border-radius: var(--radius);
              padding: 18px;
              margin: 0;
            }
            .button {
              display: inline-flex;
              align-items: center;
              justify-content: center;
              min-height: 34px;
              border-radius: var(--radius);
              padding: 0 12px;
              border: 1px solid var(--line);
              color: var(--text);
              background: var(--panel);
              text-decoration: none;
              font-size: 13px;
              font-weight: 700;
            }
            .status {
              border-radius: 999px;
              padding: 5px 10px;
              font-size: 12px;
              font-weight: 750;
              background: color-mix(in srgb, var(--accent) 18%, transparent);
              color: var(--text);
            }
            .failed { background: rgba(255, 88, 88, 0.16); }
            .inProgress { background: rgba(125, 184, 255, 0.18); }
            .metric-grid {
              display: grid;
              grid-template-columns: repeat(4, minmax(0, 1fr));
              gap: 10px;
            }
            .metric {
              min-height: 86px;
              display: grid;
              align-content: center;
              gap: 8px;
              border: 1px solid var(--line);
              border-radius: var(--radius);
              background: var(--panel);
              padding: 14px;
              box-shadow: 0 14px 34px var(--shadow);
            }
            .metric span {
              color: var(--muted);
              font-size: 12px;
              font-weight: 700;
              text-transform: uppercase;
            }
            .metric strong {
              font-size: 22px;
              line-height: 1;
            }
            .row-meta {
              display: grid;
              gap: 5px;
              justify-items: end;
            }
            .duration {
              font-size: 13px;
            }
            @media (max-width: 760px) {
              main { width: min(100vw - 28px, 1120px); padding-top: 26px; }
              header, .section-head, .list-row { grid-template-columns: 1fr; }
              header { align-items: start; }
              .settings-grid { grid-template-columns: 1fr; }
              .metric-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
              time, .status, .row-meta { justify-self: start; justify-items: start; }
            }
          </style>
        </head>
        <body>
          <main>
            <header>
              <div>
                <h1>\(settingsTitle)</h1>
                <p class="muted">Минимальные параметры, цветовые схемы, история, загрузки и состояние браузера.</p>
              </div>
              <a class="button" href="\(northStarSettingsScheme)://clear-history">Очистить историю</a>
            </header>

            <section class="settings-grid" aria-label="Минимальные настройки">
              <label>
                <span>Поиск</span>
                <select id="search">\(searchOptions)</select>
              </label>
              <label>
                <span>Вкладки</span>
                <select id="tabs">\(tabOptions)</select>
              </label>
              <label>
                <span>Тема</span>
                <select id="theme">\(themeOptions)</select>
              </label>
              <label>
                <span>Цветовая схема</span>
                <select id="scheme">\(schemeOptions)</select>
              </label>
              <label>
                <span>Дизайн</span>
                <select id="design">\(designOptions)</select>
              </label>
              <label>
                <span>Главный экран</span>
                <select id="home">\(homeOptions)</select>
              </label>
            </section>

            <section aria-label="Производительность">
              <div class="section-head">
                <div>
                  <h2>Производительность</h2>
                  <p class="muted">Лёгкий мониторинг текущего окна и последних загрузок.</p>
                </div>
              </div>
              <div class="metric-grid">
                <div class="metric"><span>Вкладки</span><strong>\(performance.activeTabs)</strong></div>
                <div class="metric"><span>Загружается</span><strong>\(performance.loadingTabs)</strong></div>
                <div class="metric"><span>Память</span><strong>\(PerformanceDisplay.memory(performance.residentMemoryMegabytes).htmlEscaped)</strong></div>
                <div class="metric"><span>Средняя загрузка</span><strong>\(PerformanceDisplay.duration(performance.averageDuration).htmlEscaped)</strong></div>
              </div>
              <div class="list">
                \(performanceMarkup.isEmpty ? "<p class=\"empty\">Данных о загрузках пока нет.</p>" : performanceMarkup)
              </div>
            </section>

            <section aria-label="История посещений">
              <div class="section-head">
                <div>
                  <h2>История посещений</h2>
                  <p class="muted">Последние открытые страницы.</p>
                </div>
                <a class="button" href="\(northStarSettingsScheme)://clear-history">Очистить</a>
              </div>
              <div class="list">
                \(historyMarkup.isEmpty ? "<p class=\"empty\">История пока пуста.</p>" : historyMarkup)
              </div>
            </section>

            <section aria-label="История загрузок">
              <div class="section-head">
                <div>
                  <h2>История загрузок</h2>
                  <p class="muted">Файлы сохраняются в папку Загрузки.</p>
                </div>
                <a class="button" href="\(northStarSettingsScheme)://clear-downloads">Очистить</a>
              </div>
              <div class="list">
                \(downloadsMarkup.isEmpty ? "<p class=\"empty\">Загрузок пока нет.</p>" : downloadsMarkup)
              </div>
            </section>
          </main>
          <script>
            const update = () => {
              const params = new URLSearchParams({
                search: document.getElementById("search").value,
                tabs: document.getElementById("tabs").value,
                theme: document.getElementById("theme").value,
                scheme: document.getElementById("scheme").value,
                design: document.getElementById("design").value,
                home: document.getElementById("home").value
              });
              window.location.href = "\(northStarSettingsScheme)://update?" + params.toString();
            };
            document.querySelectorAll("select").forEach(select => {
              select.addEventListener("change", update);
            });
          </script>
        </body>
        </html>
        """
    }
}

private struct HomePalette {
    let colorScheme: String
    let background: String
    let panel: String
    let panelStrong: String
    let text: String
    let muted: String
    let line: String
    let accent: String
    let accentTwo: String
    let shadow: String
    let radius: String
    let gap: String
    let pageWidth: String
    let settingsWidth: String

    init(theme: ThemeMode, colorScheme colorSchemeMode: ColorSchemeMode, design: DesignMode) {
        accent = colorSchemeMode.accent
        accentTwo = colorSchemeMode.accentTwo
        radius = design.radius
        gap = design.gap
        pageWidth = design.pageWidth
        settingsWidth = design.settingsWidth

        switch theme {
        case .light:
            colorScheme = "light"
            background = colorSchemeMode.lightBackground
            panel = "rgba(255,255,255,0.78)"
            panelStrong = colorSchemeMode.lightPanelStrong
            text = "#11191f"
            muted = "#52656c"
            line = "rgba(39,65,72,0.18)"
            shadow = "rgba(34,65,72,0.16)"
        case .dark:
            colorScheme = "dark"
            background = colorSchemeMode.darkBackground
            panel = "rgba(17,27,31,0.82)"
            panelStrong = colorSchemeMode.darkPanelStrong
            text = "#f4fbfc"
            muted = "#9eb5ba"
            line = "rgba(209,240,245,0.16)"
            shadow = "rgba(0,0,0,0.34)"
        case .system:
            colorScheme = "light dark"
            background = "Canvas"
            panel = "color-mix(in srgb, Canvas 78%, \(colorSchemeMode.accent) 6%)"
            panelStrong = "color-mix(in srgb, Canvas 84%, \(colorSchemeMode.accent) 10%)"
            text = "CanvasText"
            muted = "color-mix(in srgb, CanvasText 58%, transparent)"
            line = "color-mix(in srgb, CanvasText 16%, transparent)"
            shadow = "rgba(0,0,0,0.18)"
        }
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard normalized.count == 6,
              let value = Int(normalized, radix: 16) else {
            return nil
        }

        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    var urlQueryEscaped: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

@MainActor
private func makeMainMenu(appDelegate: AppDelegate) -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: appName)
    appMenu.addItem(withTitle: "О \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(withTitle: "\(settingsTitle)...", action: #selector(BrowserViewController.showSettingsCommand(_:)), keyEquivalent: ",")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Завершить \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "Файл")
    let newWindow = fileMenu.addItem(withTitle: "Новое окно", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
    newWindow.target = appDelegate
    fileMenu.addItem(withTitle: "Новая вкладка", action: #selector(BrowserViewController.newTabCommand(_:)), keyEquivalent: "t")
    fileMenu.addItem(withTitle: "Закрыть вкладку", action: #selector(BrowserViewController.closeTabCommand(_:)), keyEquivalent: "w")
    let closeWindow = fileMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    closeWindow.keyEquivalentModifierMask = [.command, .shift]
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Правка")
    editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "Вид")
    viewMenu.addItem(withTitle: "Назад", action: #selector(BrowserViewController.goBackCommand(_:)), keyEquivalent: "[")
    viewMenu.addItem(withTitle: "Вперёд", action: #selector(BrowserViewController.goForwardCommand(_:)), keyEquivalent: "]")
    viewMenu.addItem(withTitle: "Обновить", action: #selector(BrowserViewController.reloadCommand(_:)), keyEquivalent: "r")
    viewMenu.addItem(.separator())
    viewMenu.addItem(withTitle: "Предыдущая вкладка", action: #selector(BrowserViewController.previousTabCommand(_:)), keyEquivalent: "{")
    viewMenu.addItem(withTitle: "Следующая вкладка", action: #selector(BrowserViewController.nextTabCommand(_:)), keyEquivalent: "}")
    viewMenu.addItem(.separator())
    viewMenu.addItem(withTitle: "Фокус на адрес", action: #selector(BrowserViewController.focusLocation(_:)), keyEquivalent: "l")
    viewItem.submenu = viewMenu
    mainMenu.addItem(viewItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Окно")
    windowMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Масштаб", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
    windowItem.submenu = windowMenu
    mainMenu.addItem(windowItem)
    mainMenu.setSubmenu(windowMenu, for: windowItem)
    NSApplication.shared.windowsMenu = windowMenu

    return mainMenu
}
