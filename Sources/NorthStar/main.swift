import AppKit
import Network
import WebKit

private let appName = "NorthStar"
private let homeURL = URL(string: "https://duckduckgo.com")!
private let blankURL = URL(string: "about:blank")!

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
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.minSize = NSSize(width: 860, height: 520)
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
    private let sidebarView = NSVisualEffectView()
    private let sidebarTitle = NSTextField(labelWithString: appName)
    private let newTabButton = IconButton(symbolName: "plus", tooltip: "New Tab", width: 30, height: 28)
    private let tabScrollView = NSScrollView()
    private let tabStack = NSStackView()

    private let browserContentView = NSView()
    private let toolbarView = NSVisualEffectView()
    private let webContainerView = NSView()

    private let backButton = IconButton(symbolName: "chevron.left", tooltip: "Back")
    private let forwardButton = IconButton(symbolName: "chevron.right", tooltip: "Forward")
    private let homeButton = IconButton(symbolName: "house", tooltip: "Home")
    private let reloadButton = IconButton(symbolName: "arrow.clockwise", tooltip: "Reload")
    private let addressField = NSTextField()
    private let networkPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progressIndicator = NSProgressIndicator()

    private var tabs: [BrowserTab] = []
    private var activeTabID: UUID?

    private var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabID }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureLayout()
        configureSidebar()
        configureToolbar()
        addTab(profile: .system, url: homeURL, activate: true)
    }

    @objc func newTabCommand(_ sender: Any?) {
        addTab(profile: activeTab?.profile ?? .system, url: activeTab?.profile.startURL ?? homeURL, activate: true)
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
        } else {
            tab.webView.reload()
        }
    }

    @objc func focusLocation(_ sender: Any?) {
        view.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc private func goHome(_ sender: Any?) {
        guard let tab = activeTab else { return }
        load(tab.profile.startURL, in: tab)
    }

    @objc private func loadTypedAddress(_ sender: Any?) {
        guard let tab = activeTab else { return }

        guard let url = URLParser.url(from: addressField.stringValue) else {
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

    private func configureLayout() {
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.material = .sidebar
        sidebarView.blendingMode = .withinWindow
        sidebarView.state = .active

        browserContentView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sidebarView)
        view.addSubview(browserContentView)

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 228),

            browserContentView.topAnchor.constraint(equalTo: view.topAnchor),
            browserContentView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            browserContentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browserContentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureSidebar() {
        sidebarTitle.translatesAutoresizingMaskIntoConstraints = false
        sidebarTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        sidebarTitle.lineBreakMode = .byTruncatingTail

        newTabButton.target = self
        newTabButton.action = #selector(addTabFromButton(_:))

        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.drawsBackground = false
        tabScrollView.hasVerticalScroller = true
        tabScrollView.autohidesScrollers = true
        tabScrollView.borderType = .noBorder

        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabStack.orientation = .vertical
        tabStack.alignment = .width
        tabStack.spacing = 6
        tabStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 12, right: 10)

        tabScrollView.documentView = tabStack

        sidebarView.addSubview(sidebarTitle)
        sidebarView.addSubview(newTabButton)
        sidebarView.addSubview(tabScrollView)

        NSLayoutConstraint.activate([
            sidebarTitle.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 16),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 14),
            sidebarTitle.trailingAnchor.constraint(lessThanOrEqualTo: newTabButton.leadingAnchor, constant: -10),

            newTabButton.centerYAnchor.constraint(equalTo: sidebarTitle.centerYAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -12),

            tabScrollView.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 12),
            tabScrollView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            tabScrollView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            tabScrollView.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),

            tabStack.widthAnchor.constraint(equalTo: tabScrollView.contentView.widthAnchor)
        ])
    }

    private func configureToolbar() {
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.material = .headerView
        toolbarView.blendingMode = .withinWindow
        toolbarView.state = .active

        webContainerView.translatesAutoresizingMaskIntoConstraints = false
        webContainerView.wantsLayer = true
        webContainerView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: 14)
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.placeholderString = "Search or enter website"
        addressField.target = self
        addressField.action = #selector(loadTypedAddress(_:))

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

        browserContentView.addSubview(toolbarView)
        browserContentView.addSubview(webContainerView)

        [backButton, forwardButton, homeButton, addressField, networkPopup, reloadButton, progressIndicator].forEach {
            toolbarView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: browserContentView.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: browserContentView.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: browserContentView.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 52),

            webContainerView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            webContainerView.leadingAnchor.constraint(equalTo: browserContentView.leadingAnchor),
            webContainerView.trailingAnchor.constraint(equalTo: browserContentView.trailingAnchor),
            webContainerView.bottomAnchor.constraint(equalTo: browserContentView.bottomAnchor),

            backButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor, constant: -1),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            forwardButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            homeButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 8),
            homeButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            reloadButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -12),
            reloadButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            networkPopup.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -10),
            networkPopup.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            networkPopup.widthAnchor.constraint(equalToConstant: 118),

            addressField.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: 12),
            addressField.trailingAnchor.constraint(equalTo: networkPopup.leadingAnchor, constant: -12),
            addressField.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 30),

            progressIndicator.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor),
            progressIndicator.bottomAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            progressIndicator.heightAnchor.constraint(equalToConstant: 2)
        ])
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

        let targetURL = targetURLAfterChangingNetwork(from: oldTab, to: profile)
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
        load(targetURL, in: newTab)
    }

    private func targetURLAfterChangingNetwork(from tab: BrowserTab, to profile: NetworkProfile) -> URL {
        let currentURL = tab.url ?? tab.webView.url
        if let currentURL, NetworkPolicy.allows(currentURL, profile: profile) {
            return currentURL
        }

        return profile.startURL
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

        for tab in tabs {
            let row = TabRowView()
            row.configure(
                title: tab.displayTitle,
                detail: tab.profile.detail,
                isActive: tab.id == activeTabID
            )
            row.onSelect = { [weak self, id = tab.id] in
                self?.activateTab(id: id)
            }
            row.onClose = { [weak self, id = tab.id] in
                self?.closeTab(id: id)
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

    private func load(_ url: URL, in tab: BrowserTab) {
        guard NetworkPolicy.allows(url, profile: tab.profile) else {
            showBlockedURL(url, profile: tab.profile)
            syncToolbar()
            return
        }

        tab.load(url)
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
            addressField.stringValue = tab.url?.absoluteString ?? tab.webView.url?.absoluteString ?? ""
        }

        progressIndicator.doubleValue = tab.progress
        progressIndicator.isHidden = !tab.webView.isLoading || tab.progress >= 1

        if let profileIndex = NetworkProfile.allCases.firstIndex(of: tab.profile) {
            networkPopup.selectItem(at: profileIndex)
        }

        view.window?.title = tab.displayTitle == "New Tab" ? appName : "\(tab.displayTitle) - \(appName)"
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

    private(set) var title = "New Tab"
    private(set) var url: URL?
    private(set) var progress = 0.0
    private var observations: [NSKeyValueObservation] = []

    var displayTitle: String {
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

    func load(_ url: URL) {
        self.url = url
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
        url = webView.url ?? url
        title = Self.normalizedTitle(webView.title)
        progress = webView.estimatedProgress
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
                    self?.url = webView.url
                    self?.notifyChanged()
                }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.title = Self.normalizedTitle(webView.title)
                    self?.notifyChanged()
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

    private static func normalizedTitle(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "New Tab" : trimmed
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
            return "No persistent data"
        case .tor:
            return "127.0.0.1:9050"
        case .localhost:
            return "Local only"
        }
    }

    var startURL: URL {
        switch self {
        case .localhost:
            return blankURL
        default:
            return homeURL
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

    private let titleField = NSTextField(labelWithString: "New Tab")
    private let detailField = NSTextField(labelWithString: "")
    private let closeButton = IconButton(symbolName: "xmark", tooltip: "Close Tab", width: 24, height: 22)
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail

        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))

        addSubview(titleField)
        addSubview(detailField)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),

            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
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

    func configure(title: String, detail: String, isActive: Bool) {
        titleField.stringValue = title
        detailField.stringValue = detail
        self.isActive = isActive
        updateStyle()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closePressed(_ sender: Any?) {
        onClose?()
    }

    private func updateStyle() {
        layer?.backgroundColor = isActive
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
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
    static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return homeURL }

        if let directURL = URL(string: trimmed),
           let scheme = directURL.scheme?.lowercased(),
           ["http", "https", "file"].contains(scheme) {
            return directURL
        }

        if looksLikeHost(trimmed) {
            return URL(string: "\(defaultScheme(for: trimmed))://\(trimmed)")
        }

        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return URL(string: "https://duckduckgo.com/?q=\(query)")
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

@MainActor
private func makeMainMenu(appDelegate: AppDelegate) -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: appName)
    appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
