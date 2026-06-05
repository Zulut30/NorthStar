import AppKit
import Network
import WebKit

private let appName = "NorthStar"
private let blankURL = URL(string: "about:blank")!
private let northStarSearchScheme = "northstar-search"

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
    private let tabBarTitle = NSTextField(labelWithString: "Tabs")
    private let newTabButton = IconButton(symbolName: "plus", tooltip: "New Tab", width: 30, height: 28)
    private let tabScrollView = NSScrollView()
    private let tabStack = NSStackView()

    private let browserContentView = NSView()
    private let toolbarView = NSVisualEffectView()
    private let brandTitleField = NSTextField(labelWithString: appName)
    private let webContainerView = NSView()

    private let backButton = IconButton(symbolName: "chevron.left", tooltip: "Back")
    private let forwardButton = IconButton(symbolName: "chevron.right", tooltip: "Forward")
    private let homeButton = IconButton(symbolName: "house", tooltip: "Home")
    private let reloadButton = IconButton(symbolName: "arrow.clockwise", tooltip: "Reload")
    private let settingsButton = IconButton(symbolName: "gearshape", tooltip: "Settings")
    private let addressField = NSTextField()
    private let searchEnginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let networkPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progressIndicator = NSProgressIndicator()

    private var placementConstraints: [NSLayoutConstraint] = []
    private var tabBarContentConstraints: [NSLayoutConstraint] = []
    private var tabStackCrossAxisConstraint: NSLayoutConstraint?
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
        } else {
            tab.webView.reload()
        }
    }

    @objc func focusLocation(_ sender: Any?) {
        view.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc func showSettingsCommand(_ sender: Any?) {
        let controller = SettingsViewController(preferences: preferences)
        presentAsSheet(controller)
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
        addressField.placeholderString = "Search or enter website"
        addressField.target = self
        addressField.action = #selector(loadTypedAddress(_:))

        searchEnginePopup.translatesAutoresizingMaskIntoConstraints = false
        searchEnginePopup.controlSize = .regular
        searchEnginePopup.font = .systemFont(ofSize: 13)
        searchEnginePopup.target = self
        searchEnginePopup.action = #selector(searchEngineSelectionChanged(_:))
        searchEnginePopup.toolTip = "Search Engine"
        searchEnginePopup.removeAllItems()
        searchEnginePopup.addItems(withTitles: SearchEngine.allCases.map(\.title))

        networkPopup.translatesAutoresizingMaskIntoConstraints = false
        networkPopup.controlSize = .regular
        networkPopup.font = .systemFont(ofSize: 13)
        networkPopup.target = self
        networkPopup.action = #selector(networkSelectionChanged(_:))
        networkPopup.toolTip = "Network"
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

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: browserContentView.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: browserContentView.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: browserContentView.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 56),

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
        applyChromeTheme()
        applyTabPlacement(preferences.tabPlacement)

        if redrawHomeTabs {
            tabs.filter(\.isShowingHome).forEach { showHome(in: $0) }
        }

        renderTabs()
        syncToolbar()
    }

    private func applyChromeTheme() {
        let colors = ChromePalette(theme: preferences.theme)
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
                tabBarView.widthAnchor.constraint(equalToConstant: 276),

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
                tabBarView.widthAnchor.constraint(equalToConstant: 276)
            ]
        case .top:
            placementConstraints = [
                tabBarView.topAnchor.constraint(equalTo: view.topAnchor),
                tabBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tabBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                tabBarView.heightAnchor.constraint(equalToConstant: 96),

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
                tabBarView.heightAnchor.constraint(equalToConstant: 96)
            ]
        }

        NSLayoutConstraint.activate(placementConstraints)
        applyTabBarContentLayout(placement)
    }

    private func applyTabBarContentLayout(_ placement: TabPlacement) {
        NSLayoutConstraint.deactivate(tabBarContentConstraints)
        tabStackCrossAxisConstraint?.isActive = false

        let isHorizontal = placement.isHorizontal
        tabBarTitle.isHidden = false
        tabBarTitle.stringValue = placement == .top ? appName : "Tabs"
        tabStack.orientation = isHorizontal ? .horizontal : .vertical
        tabStack.alignment = isHorizontal ? .height : .width
        tabStack.edgeInsets = isHorizontal
            ? NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 14)
            : NSEdgeInsets(top: 10, left: 12, bottom: 14, right: 12)
        tabScrollView.hasHorizontalScroller = isHorizontal
        tabScrollView.hasVerticalScroller = !isHorizontal

        if isHorizontal {
            tabBarContentConstraints = [
                tabBarHeaderView.topAnchor.constraint(equalTo: tabBarView.topAnchor),
                tabBarHeaderView.leadingAnchor.constraint(equalTo: tabBarView.leadingAnchor),
                tabBarHeaderView.bottomAnchor.constraint(equalTo: tabBarView.bottomAnchor),
                tabBarHeaderView.widthAnchor.constraint(equalToConstant: 176),

                tabBarTitle.leadingAnchor.constraint(equalTo: tabBarHeaderView.leadingAnchor, constant: 16),
                tabBarTitle.centerYAnchor.constraint(equalTo: tabBarHeaderView.centerYAnchor),
                tabBarTitle.trailingAnchor.constraint(lessThanOrEqualTo: newTabButton.leadingAnchor, constant: -10),

                newTabButton.centerYAnchor.constraint(equalTo: tabBarHeaderView.centerYAnchor),
                newTabButton.trailingAnchor.constraint(equalTo: tabBarHeaderView.trailingAnchor, constant: -12),

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

        let targetURL = oldTab.isShowingHome ? nil : oldTab.url ?? oldTab.webView.url
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

        if let targetURL, NetworkPolicy.allows(targetURL, profile: profile) {
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
                isHorizontal: isHorizontal
            )
            row.onSelect = { [weak self, id = tab.id] in
                self?.activateTab(id: id)
            }
            row.onClose = { [weak self, id = tab.id] in
                self?.closeTab(id: id)
            }

            if isHorizontal {
                row.widthAnchor.constraint(equalToConstant: 238).isActive = true
            }

            tabStack.addArrangedSubview(row)
        }
    }

    private func tabStateDidChange(_ tab: BrowserTab) {
        if tab.id == activeTabID {
            syncToolbar()
        }

        renderTabs()
    }

    private func showHome(in tab: BrowserTab) {
        tab.loadHomePage(searchEngine: preferences.searchEngine, theme: preferences.theme)
    }

    private func load(_ url: URL, in tab: BrowserTab) {
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
        reloadButton.image = NSImage(systemSymbolName: reloadSymbol, accessibilityDescription: tab.webView.isLoading ? "Stop" : "Reload")
        reloadButton.toolTip = tab.webView.isLoading ? "Stop" : "Reload"

        if !isEditingAddress {
            addressField.stringValue = tab.isShowingHome ? "" : tab.url?.absoluteString ?? tab.webView.url?.absoluteString ?? ""
        }

        progressIndicator.doubleValue = tab.progress
        progressIndicator.isHidden = tab.isShowingHome || !tab.webView.isLoading || tab.progress >= 1

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
        alert.messageText = "Navigation blocked"
        alert.informativeText = "\(profile.title) does not allow \(url.absoluteString)."
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
        alert.messageText = "Could not load page"

        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension BrowserViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab(for: webView)?.syncFromWebView()
        syncToolbar()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab(for: webView)?.syncFromWebView()
        syncToolbar()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab(for: webView)?.syncFromWebView()
        syncToolbar()
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab(for: webView)?.syncFromWebView()
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
}

extension BrowserViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            let profile = tab(for: webView)?.profile ?? activeTab?.profile ?? .system
            addTab(profile: profile, url: url, activate: true)
        }

        return nil
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
    private var observations: [NSKeyValueObservation] = []

    var displayTitle: String {
        if isShowingHome {
            return appName
        }

        if !title.isEmpty {
            return title
        }

        if let host = url?.host(percentEncoded: false), !host.isEmpty {
            return host
        }

        return "New Tab"
    }

    init(profile: NetworkProfile) {
        self.profile = profile
        webView = WKWebView(frame: .zero, configuration: profile.makeWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        bindWebViewState()
    }

    func loadHomePage(searchEngine: SearchEngine, theme: ThemeMode) {
        isShowingHome = true
        title = appName
        url = nil
        progress = 1
        notifyChanged()
        webView.loadHTMLString(HomePage.html(searchEngine: searchEngine, theme: theme), baseURL: nil)
    }

    func load(_ url: URL) {
        isShowingHome = false
        self.url = url
        title = Self.normalizedTitle(url.host(percentEncoded: false)) ?? "Loading"
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
        } else {
            url = webView.url ?? url
            title = Self.normalizedTitle(webView.title) ?? Self.normalizedTitle(url?.host(percentEncoded: false)) ?? "New Tab"
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
                    if !self.isShowingHome {
                        self.url = webView.url
                    }
                    self.notifyChanged()
                }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.title = self.isShowingHome ? appName : Self.normalizedTitle(webView.title) ?? self.title
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

@MainActor
private final class SettingsViewController: NSViewController {
    private let preferences: AppPreferences
    private let searchPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tabPlacementPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    init(preferences: AppPreferences) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 440, height: 254)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = NSTextField(labelWithString: "Settings")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 22, weight: .bold)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 14

        configurePopup(searchPopup, titles: SearchEngine.allCases.map(\.title), selectedIndex: preferences.searchEngine.rawValue, action: #selector(searchChanged(_:)))
        configurePopup(tabPlacementPopup, titles: TabPlacement.allCases.map(\.title), selectedIndex: preferences.tabPlacement.rawValue, action: #selector(tabPlacementChanged(_:)))
        configurePopup(themePopup, titles: ThemeMode.allCases.map(\.title), selectedIndex: preferences.theme.rawValue, action: #selector(themeChanged(_:)))

        stack.addArrangedSubview(settingsRow(label: "Search engine", control: searchPopup))
        stack.addArrangedSubview(settingsRow(label: "Tabs position", control: tabPlacementPopup))
        stack.addArrangedSubview(settingsRow(label: "Theme", control: themePopup))

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(done(_:))

        view.addSubview(title)
        view.addSubview(stack)
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            stack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            doneButton.widthAnchor.constraint(equalToConstant: 88)
        ])
    }

    private func configurePopup(_ popup: NSPopUpButton, titles: [String], selectedIndex: Int, action: Selector) {
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.selectItem(at: selectedIndex)
        popup.target = self
        popup.action = action
        popup.widthAnchor.constraint(equalToConstant: 190).isActive = true
    }

    private func settingsRow(label: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18

        let labelField = NSTextField(labelWithString: label)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = .systemFont(ofSize: 13, weight: .medium)
        labelField.widthAnchor.constraint(equalToConstant: 142).isActive = true

        row.addArrangedSubview(labelField)
        row.addArrangedSubview(control)
        return row
    }

    @objc private func searchChanged(_ sender: Any?) {
        preferences.searchEngine = SearchEngine(rawValue: searchPopup.indexOfSelectedItem) ?? .duckDuckGo
    }

    @objc private func tabPlacementChanged(_ sender: Any?) {
        preferences.tabPlacement = TabPlacement(rawValue: tabPlacementPopup.indexOfSelectedItem) ?? .left
    }

    @objc private func themeChanged(_ sender: Any?) {
        preferences.theme = ThemeMode(rawValue: themePopup.indexOfSelectedItem) ?? .system
    }

    @objc private func done(_ sender: Any?) {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
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

    private enum Keys {
        static let searchEngine = "searchEngine"
        static let tabPlacement = "tabPlacement"
        static let theme = "theme"
    }

    private let defaults = UserDefaults.standard

    private init() {
        searchEngine = SearchEngine(rawValue: defaults.integer(forKey: Keys.searchEngine)) ?? .duckDuckGo
        tabPlacement = TabPlacement(rawValue: defaults.integer(forKey: Keys.tabPlacement)) ?? .left
        theme = ThemeMode(rawValue: defaults.integer(forKey: Keys.theme)) ?? .system
    }

    private func saveAndNotify(key: String, value: Int) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
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
            return "Left"
        case .top:
            return "Top"
        case .right:
            return "Right"
        case .bottom:
            return "Bottom"
        }
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
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
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

    init(theme: ThemeMode) {
        switch theme {
        case .light:
            window = NSColor(red: 0.95, green: 0.97, blue: 0.98, alpha: 1)
            webBackground = NSColor(red: 0.98, green: 0.99, blue: 1, alpha: 1)
            brand = NSColor(red: 0.08, green: 0.13, blue: 0.18, alpha: 1)
            secondaryText = NSColor(red: 0.36, green: 0.43, blue: 0.48, alpha: 1)
        case .dark:
            window = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
            webBackground = NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)
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
            return "System"
        case .privateBrowsing:
            return "Private"
        case .tor:
            return "Tor SOCKS"
        case .localhost:
            return "Localhost"
        }
    }

    var detail: String {
        switch self {
        case .system:
            return "Default network"
        case .privateBrowsing:
            return "Private data"
        case .tor:
            return "127.0.0.1:9050"
        case .localhost:
            return "Local only"
        }
    }

    @MainActor
    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

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

private enum NetworkPolicy {
    static func allows(_ url: URL, profile: NetworkProfile) -> Bool {
        guard profile == .localhost else { return true }

        guard let scheme = url.scheme?.lowercased() else { return false }

        if ["about", "file", "data", "blob"].contains(scheme) {
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

@MainActor
private final class TabRowView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let indicatorView = NSView()
    private let titleField = NSTextField(labelWithString: "New Tab")
    private let detailField = NSTextField(labelWithString: "")
    private let closeButton = IconButton(symbolName: "xmark", tooltip: "Close Tab", width: 24, height: 22)
    private var isActive = false
    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.wantsLayer = true
        indicatorView.layer?.cornerRadius = 2

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail

        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))

        addSubview(indicatorView)
        addSubview(titleField)
        addSubview(detailField)
        addSubview(closeButton)

        let height = heightAnchor.constraint(equalToConstant: 48)
        heightConstraint = height

        NSLayoutConstraint.activate([
            height,

            indicatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            indicatorView.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            indicatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            indicatorView.widthAnchor.constraint(equalToConstant: 4),

            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleField.leadingAnchor.constraint(equalTo: indicatorView.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),

            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7)
        ])

        updateStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(title: String, detail: String, isActive: Bool, isHorizontal: Bool) {
        titleField.stringValue = title
        detailField.stringValue = detail
        self.isActive = isActive
        heightConstraint?.constant = isHorizontal ? 62 : 58
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
        layer?.backgroundColor = isActive
            ? accent.withAlphaComponent(0.18).cgColor
            : NSColor.controlBackgroundColor.withAlphaComponent(0.42).cgColor
        layer?.borderColor = isActive
            ? accent.withAlphaComponent(0.55).cgColor
            : NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        indicatorView.layer?.backgroundColor = isActive
            ? accent.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        detailField.textColor = isActive ? .labelColor : .secondaryLabelColor
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
    static func html(searchEngine: SearchEngine, theme: ThemeMode) -> String {
        let palette = HomePalette(theme: theme)
        let engine = searchEngine.title.htmlEscaped
        let engineOptions = SearchEngine.allCases.map { option in
            let selected = option == searchEngine ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()

        return """
        <!doctype html>
        <html lang="en">
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
            }
            * { box-sizing: border-box; }
            html, body { margin: 0; min-height: 100%; }
            body {
              min-height: 100vh;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif;
              color: var(--text);
              background:
                linear-gradient(120deg, var(--bg) 0%, var(--panel-strong) 54%, var(--bg) 100%);
              display: grid;
              place-items: center;
              overflow: hidden;
            }
            main {
              width: min(860px, calc(100vw - 48px));
              display: grid;
              gap: 28px;
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
              border-radius: 18px;
              box-shadow: 0 26px 70px var(--shadow);
            }
            input {
              width: 100%;
              min-width: 0;
              border: 0;
              outline: 0;
              border-radius: 12px;
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
              border-radius: 12px;
              padding: 0 14px;
              font-size: 15px;
              font-weight: 650;
              color: var(--text);
              background: color-mix(in srgb, var(--panel) 72%, transparent);
            }
            button {
              border: 0;
              border-radius: 12px;
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
              border-radius: 14px;
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
              <p class="sub">Search, open a site, or start from a familiar place.</p>
            </section>
            <form class="search" id="searchForm">
              <input id="query" name="q" autofocus autocomplete="off" placeholder="Search or enter website">
              <select id="engine" name="engine" aria-label="Search engine">
                \(engineOptions)
              </select>
              <button type="submit">Go</button>
            </form>
            <div class="engine">Current search engine: \(engine)</div>
            <nav class="quick" aria-label="Quick links">
              <a href="https://github.com">GitHub</a>
              <a href="https://news.ycombinator.com">Hacker News</a>
              <a href="https://developer.apple.com">Apple Dev</a>
              <a href="http://localhost:3000">Localhost</a>
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

    init(theme: ThemeMode) {
        switch theme {
        case .light:
            colorScheme = "light"
            background = "#eff6f7"
            panel = "rgba(255,255,255,0.78)"
            panelStrong = "#dbe8e8"
            text = "#11191f"
            muted = "#52656c"
            line = "rgba(39,65,72,0.18)"
            accent = "#47d6b0"
            accentTwo = "#7bb8ff"
            shadow = "rgba(34,65,72,0.16)"
        case .dark:
            colorScheme = "dark"
            background = "#071013"
            panel = "rgba(17,27,31,0.82)"
            panelStrong = "#17252a"
            text = "#f4fbfc"
            muted = "#9eb5ba"
            line = "rgba(209,240,245,0.16)"
            accent = "#6ee7c7"
            accentTwo = "#8dc7ff"
            shadow = "rgba(0,0,0,0.34)"
        case .system:
            colorScheme = "light dark"
            background = "Canvas"
            panel = "color-mix(in srgb, Canvas 78%, CanvasText 4%)"
            panelStrong = "color-mix(in srgb, Canvas 84%, #47d6b0 10%)"
            text = "CanvasText"
            muted = "color-mix(in srgb, CanvasText 58%, transparent)"
            line = "color-mix(in srgb, CanvasText 16%, transparent)"
            accent = "#6ee7c7"
            accentTwo = "#8dc7ff"
            shadow = "rgba(0,0,0,0.18)"
        }
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
}

@MainActor
private func makeMainMenu(appDelegate: AppDelegate) -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: appName)
    appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(withTitle: "Settings...", action: #selector(BrowserViewController.showSettingsCommand(_:)), keyEquivalent: ",")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let newWindow = fileMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
    newWindow.target = appDelegate
    fileMenu.addItem(withTitle: "New Tab", action: #selector(BrowserViewController.newTabCommand(_:)), keyEquivalent: "t")
    fileMenu.addItem(withTitle: "Close Tab", action: #selector(BrowserViewController.closeTabCommand(_:)), keyEquivalent: "w")
    let closeWindow = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    closeWindow.keyEquivalentModifierMask = [.command, .shift]
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(withTitle: "Back", action: #selector(BrowserViewController.goBackCommand(_:)), keyEquivalent: "[")
    viewMenu.addItem(withTitle: "Forward", action: #selector(BrowserViewController.goForwardCommand(_:)), keyEquivalent: "]")
    viewMenu.addItem(withTitle: "Reload", action: #selector(BrowserViewController.reloadCommand(_:)), keyEquivalent: "r")
    viewMenu.addItem(.separator())
    viewMenu.addItem(withTitle: "Previous Tab", action: #selector(BrowserViewController.previousTabCommand(_:)), keyEquivalent: "{")
    viewMenu.addItem(withTitle: "Next Tab", action: #selector(BrowserViewController.nextTabCommand(_:)), keyEquivalent: "}")
    viewMenu.addItem(.separator())
    viewMenu.addItem(withTitle: "Focus Location", action: #selector(BrowserViewController.focusLocation(_:)), keyEquivalent: "l")
    viewItem.submenu = viewMenu
    mainMenu.addItem(viewItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
    windowItem.submenu = windowMenu
    mainMenu.addItem(windowItem)
    mainMenu.setSubmenu(windowMenu, for: windowItem)
    NSApplication.shared.windowsMenu = windowMenu

    return mainMenu
}
