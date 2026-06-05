import AppKit
import CoreServices
import Darwin
import Network
import UniformTypeIdentifiers
import WebKit

private let appName = "NorthStar"
private let settingsTitle = "Настройки"
private let parserTitle = "Парсер"
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

    func application(_ application: NSApplication, open urls: [URL]) {
        openExternalURLs(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openExternalURLs([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openExternalURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
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

    private func openExternalURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let controller = windows.first { $0.window?.isVisible == true } ?? {
            let controller = BrowserWindowController()
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.windows.removeAll { $0 === controller }
            }
            windows.append(controller)
            controller.showWindow(nil)
            return controller
        }()

        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        urls.forEach { controller.openExternalURL($0) }
    }
}

@MainActor
private final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let browserViewController: BrowserViewController

    init() {
        browserViewController = BrowserViewController()
        let window = NSWindow(contentViewController: browserViewController)
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

    func openExternalURL(_ url: URL) {
        browserViewController.openExternalURL(url)
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
    private let hardReloadButton = ToolbarActionButton(symbolName: "arrow.clockwise.circle", title: "Без кэша", tooltip: "Жёсткое обновление без кэша", width: 94)
    private let privateButton = ToolbarActionButton(symbolName: "eye.slash", title: "Приватно", tooltip: "Новая приватная вкладка", width: 92)
    private let screenshotButton = ToolbarActionButton(symbolName: "camera.viewfinder", title: "Снимок", tooltip: "Скопировать скриншот вкладки", width: 84)
    private let currencyButton = ToolbarActionButton(symbolName: "dollarsign.circle", title: "Валюта", tooltip: "Конвертер валют", width: 82)
    private let parserButton = ToolbarActionButton(symbolName: "doc.text.magnifyingglass", title: "Парсер", tooltip: "Разобрать текущую страницу", width: 80)
    private let settingsButton = ToolbarActionButton(symbolName: "gearshape", title: "Настройки", tooltip: settingsTitle, width: 104)
    private let addressField = NSTextField()
    private let addressSuggestionPopover = NSPopover()
    private let addressSuggestionViewController = AddressSuggestionViewController()
    private let currencyPopover = NSPopover()
    private let currencyViewController = CurrencyConverterViewController()
    private let searchEnginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let networkPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progressIndicator = NSProgressIndicator()

    private weak var screenshotEffectView: NSView?
    private var screenshotSound: NSSound?
    private var placementConstraints: [NSLayoutConstraint] = []
    private var tabBarContentConstraints: [NSLayoutConstraint] = []
    private var tabStackCrossAxisConstraint: NSLayoutConstraint?
    private var toolbarHeightConstraint: NSLayoutConstraint?
    private var activeDownloads: [ObjectIdentifier: UUID] = [:]
    private var privateDownloads: Set<ObjectIdentifier> = []
    private var activeAddressSuggestions: [AddressSuggestion] = []
    private var selectedAddressSuggestionIndex: Int?
    private var defaultAppStatusMessage: String?
    private var tabs: [BrowserTab] = []
    private var activeTabID: UUID?

    private var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabID }
    }

    private static let currencyScanScript = #"""
    (() => {
      const text = String(document.body?.innerText || "")
        .replace(/\u00a0/g, " ")
        .slice(0, 180000);
      const patterns = [
        /(?:PLN|zł|zl|EUR|€|USD|US\$|\$|GBP|£|UAH|грн|₴|RUB|руб|₽|CHF|CZK|Kč|SEK|NOK|DKK|CAD|AUD|JPY|¥)\s*[0-9][0-9\s.,–-]*/gi,
        /[0-9][0-9\s.,–-]*\s*(?:PLN|zł|zl|EUR|€|USD|US\$|\$|GBP|£|UAH|грн|₴|RUB|руб|₽|CHF|CZK|Kč|SEK|NOK|DKK|CAD|AUD|JPY|¥)/gi
      ];
      const seen = new Set();
      const results = [];
      for (const pattern of patterns) {
        for (const match of text.matchAll(pattern)) {
          const value = String(match[0] || "").replace(/\s+/g, " ").trim();
          if (value.length < 2 || seen.has(value)) continue;
          seen.add(value);
          results.push(value);
          if (results.length >= 30) return JSON.stringify(results);
        }
      }
      return JSON.stringify(results);
    })()
    """#

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

    @objc func newPrivateTabCommand(_ sender: Any?) {
        addTab(profile: .privateBrowsing, url: nil, activate: true)
    }

    @objc func screenshotTabCommand(_ sender: Any?) {
        guard let tab = activeTab, !tab.webView.bounds.isEmpty else {
            NSSound.beep()
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = tab.webView.bounds

        screenshotButton.isEnabled = false
        playScreenshotCaptureEffect()
        tab.webView.takeSnapshot(with: configuration) { [weak self] image, error in
            Task { @MainActor in
                guard let self else { return }
                self.screenshotButton.isEnabled = true

                guard let image else {
                    self.showScreenshotError(error)
                    return
                }

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()

                if !pasteboard.writeObjects([image]) {
                    self.showScreenshotError(nil)
                }
            }
        }
    }

    @objc func showCurrencyConverterCommand(_ sender: Any?) {
        showCurrencyConverter(prefilled: nil, autoConvert: false, scanPageOnOpen: true)
    }

    @objc func convertSelectionCurrencyCommand(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let webView = menuItem.representedObject as? WKWebView else {
            NSSound.beep()
            return
        }

        webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let selectedText = (result as? String) ?? ""
                guard let amount = CurrencyAmountParser.parse(
                    selectedText,
                    defaultCurrency: self.preferences.defaultCurrencySource
                ) else {
                    self.showCurrencyError(message: "Не удалось распознать цену в выделенном тексте.")
                    return
                }

                self.showCurrencyConverter(prefilled: amount, autoConvert: true)
            }
        }
    }

    @objc func scanPageCurrencyCommand(_ sender: Any?) {
        if let menuItem = sender as? NSMenuItem,
           let webView = menuItem.representedObject as? WKWebView {
            showCurrencyConverter(prefilled: nil, autoConvert: false, scanPageOnOpen: false)
            scanCurrencyAmount(from: webView, autoConvert: true)
            return
        }

        showCurrencyConverter(prefilled: nil, autoConvert: false, scanPageOnOpen: true)
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
        } else if tab.isShowingParser, let snapshot = tab.parserSnapshot {
            tab.loadParserPage(snapshot: snapshot, theme: preferences.theme, colorScheme: preferences.colorScheme, design: preferences.design)
        } else {
            tab.webView.reload()
        }
    }

    @objc func hardReloadCommand(_ sender: Any?) {
        guard let tab = activeTab else { return }

        if tab.isShowingHome {
            showHome(in: tab)
        } else if tab.isShowingSettings {
            showSettings(in: tab)
        } else if tab.isShowingParser, let snapshot = tab.parserSnapshot {
            tab.loadParserPage(snapshot: snapshot, theme: preferences.theme, colorScheme: preferences.colorScheme, design: preferences.design)
        } else {
            tab.webView.stopLoading()
            tab.webView.reloadFromOrigin()
        }
    }

    @objc func focusLocation(_ sender: Any?) {
        view.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc func showSettingsCommand(_ sender: Any?) {
        openSettingsTab()
    }

    @objc func openParserCommand(_ sender: Any?) {
        guard let tab = activeTab else { return }
        Task { @MainActor in
            await openParserTab(from: tab)
        }
    }

    func openExternalURL(_ url: URL) {
        let targetURL = url.isFileURL ? url : url.standardized

        if let tab = activeTab,
           tab.isShowingHome,
           NetworkPolicy.allows(targetURL, profile: tab.profile) {
            load(targetURL, in: tab)
            return
        }

        let profile = activeTab?.profile ?? .system
        addTab(profile: profile, url: targetURL, activate: true)
    }

    @objc private func goHome(_ sender: Any?) {
        guard let tab = activeTab else { return }
        showHome(in: tab)
    }

    @objc private func loadTypedAddress(_ sender: Any?) {
        guard let tab = activeTab else { return }

        let trimmed = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        hideAddressSuggestions()
        if trimmed.isEmpty {
            showHome(in: tab)
            return
        }

        guard let url = URLParser.url(
            from: trimmed,
            searchEngine: preferences.searchEngine,
            region: preferences.searchRegion,
            language: preferences.searchLanguage
        ) else {
            NSSound.beep()
            return
        }

        load(url, in: tab)
    }

    private func updateAddressSuggestions() {
        guard isEditingAddress else {
            hideAddressSuggestions()
            return
        }

        let trimmed = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hideAddressSuggestions()
            return
        }

        activeAddressSuggestions = addressSuggestions(for: trimmed)
        selectedAddressSuggestionIndex = activeAddressSuggestions.isEmpty ? nil : 0

        guard !activeAddressSuggestions.isEmpty else {
            hideAddressSuggestions()
            return
        }

        renderAddressSuggestions()
        showAddressSuggestions()
    }

    private func addressSuggestions(for query: String) -> [AddressSuggestion] {
        let normalizedQuery = query.lowercased()
        var suggestions: [AddressSuggestion] = []
        var seen = Set<String>()

        func append(_ suggestion: AddressSuggestion) {
            guard seen.insert(suggestion.identity).inserted else { return }
            suggestions.append(suggestion)
        }

        if let directURL = URLParser.directURL(from: query) {
            append(
                AddressSuggestion(
                    title: "Открыть сайт",
                    detail: AddressSuggestion.displayText(for: directURL).truncatedForSuggestion(maxLength: 96),
                    input: directURL.absoluteString,
                    url: directURL,
                    symbolName: "globe"
                )
            )
        }

        if let searchURL = preferences.searchEngine.searchURL(
            for: query,
            region: preferences.searchRegion,
            language: preferences.searchLanguage
        ) {
            append(
                AddressSuggestion(
                    title: "Искать «\(query)»",
                    detail: "\(preferences.searchEngine.title) · \(preferences.searchRegion.title) · \(preferences.searchLanguage.title)",
                    input: query,
                    url: searchURL,
                    symbolName: "magnifyingglass",
                    identity: "search:\(preferences.searchEngine.identifier):\(query)"
                )
            )
        }

        guard query.count >= 2 else {
            return Array(suggestions.prefix(5))
        }

        for entry in BrowserHistoryStore.shared.entries {
            let title = entry.title.lowercased()
            let url = entry.url.lowercased()
            guard title.contains(normalizedQuery) || url.contains(normalizedQuery),
                  let entryURL = URL(string: entry.url) else {
                continue
            }

            append(
                AddressSuggestion(
                    title: entry.title.truncatedForSuggestion(maxLength: 76),
                    detail: entry.url.truncatedForSuggestion(maxLength: 110),
                    input: entry.url,
                    url: entryURL,
                    symbolName: "clock"
                )
            )

            if suggestions.count >= 5 {
                break
            }
        }

        return Array(suggestions.prefix(5))
    }

    private func renderAddressSuggestions() {
        addressSuggestionViewController.update(
            suggestions: activeAddressSuggestions,
            selectedIndex: selectedAddressSuggestionIndex,
            width: addressField.bounds.width
        )
        addressSuggestionPopover.contentSize = addressSuggestionViewController.preferredContentSize
    }

    private func showAddressSuggestions() {
        guard !addressSuggestionPopover.isShown else { return }

        addressSuggestionPopover.show(
            relativeTo: addressField.bounds,
            of: addressField,
            preferredEdge: .maxY
        )
    }

    private func hideAddressSuggestions() {
        activeAddressSuggestions = []
        selectedAddressSuggestionIndex = nil
        addressSuggestionPopover.close()
    }

    private func moveAddressSuggestionSelection(by offset: Int) {
        guard !activeAddressSuggestions.isEmpty else { return }

        if let selectedAddressSuggestionIndex {
            let nextIndex = (selectedAddressSuggestionIndex + offset + activeAddressSuggestions.count) % activeAddressSuggestions.count
            self.selectedAddressSuggestionIndex = nextIndex
        } else {
            selectedAddressSuggestionIndex = offset >= 0 ? 0 : activeAddressSuggestions.count - 1
        }

        renderAddressSuggestions()
        showAddressSuggestions()
    }

    private func applySelectedAddressSuggestion() -> Bool {
        guard let selectedAddressSuggestionIndex,
              activeAddressSuggestions.indices.contains(selectedAddressSuggestionIndex) else {
            return false
        }

        applyAddressSuggestion(activeAddressSuggestions[selectedAddressSuggestionIndex])
        return true
    }

    private func applyAddressSuggestion(_ suggestion: AddressSuggestion) {
        hideAddressSuggestions()
        addressField.stringValue = suggestion.input

        guard let tab = activeTab else { return }

        if let url = suggestion.url {
            load(url, in: tab)
            return
        }

        guard let url = URLParser.url(
            from: suggestion.input,
            searchEngine: preferences.searchEngine,
            region: preferences.searchRegion,
            language: preferences.searchLanguage
        ) else {
            NSSound.beep()
            return
        }

        load(url, in: tab)
    }

    private func showCurrencyConverter(prefilled amount: CurrencyAmount?, autoConvert: Bool, scanPageOnOpen: Bool = false) {
        let source = amount?.currency ?? preferences.defaultCurrencySource
        let canScanPage = activeTab.map { !$0.isShowingHome && !$0.isShowingSettings && !$0.isShowingParser } ?? false
        currencyViewController.configure(
            amount: amount?.amount,
            source: source,
            target: preferences.defaultCurrencyTarget,
            apiKeyPresent: !preferences.currencyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            canScanPage: canScanPage
        )

        if !currencyPopover.isShown {
            currencyPopover.show(relativeTo: currencyButton.bounds, of: currencyButton, preferredEdge: .minY)
        }

        if scanPageOnOpen, amount == nil, canScanPage, let webView = activeTab?.webView {
            scanCurrencyAmount(from: webView, autoConvert: true)
            return
        }

        if autoConvert {
            let request = CurrencyConversionRequest(
                amount: amount?.amount ?? 0,
                source: source,
                target: preferences.defaultCurrencyTarget
            )
            runCurrencyConversion(request)
        }
    }

    private func runCurrencyConversion(_ request: CurrencyConversionRequest) {
        let apiKey = preferences.currencyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            currencyViewController.showError("Ключ ExchangeRate-API не настроен локально.")
            return
        }

        guard request.amount > 0 else {
            currencyViewController.showError("Введите сумму больше нуля.")
            return
        }

        currencyViewController.showLoading()
        Task { @MainActor in
            do {
                let result = try await CurrencyConverterService.convert(
                    amount: request.amount,
                    source: request.source,
                    target: request.target,
                    apiKey: apiKey
                )
                currencyViewController.showResult(result)
            } catch {
                currencyViewController.showError(error.localizedDescription)
            }
        }
    }

    private func scanCurrencyAmount(from webView: WKWebView, autoConvert: Bool) {
        currencyViewController.showScanning()
        Task { @MainActor in
            do {
                let amount = try await Self.detectCurrencyAmount(in: webView, defaultCurrency: preferences.defaultCurrencySource)
                showCurrencyConverter(prefilled: amount, autoConvert: autoConvert)
            } catch {
                currencyViewController.showError(error.localizedDescription)
            }
        }
    }

    private static func detectCurrencyAmount(in webView: WKWebView, defaultCurrency: CurrencyCode) async throws -> CurrencyAmount {
        guard let json = try await webView.evaluateJavaScript(currencyScanScript) as? String,
              let data = json.data(using: .utf8),
              let fragments = try? JSONDecoder().decode([String].self, from: data),
              let amount = CurrencyAmountParser.bestCandidate(in: fragments, defaultCurrency: defaultCurrency) else {
            throw CurrencyScanError.notFound
        }

        return amount
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
        addressField.delegate = self

        addressSuggestionPopover.behavior = .semitransient
        addressSuggestionPopover.animates = false
        addressSuggestionPopover.contentViewController = addressSuggestionViewController
        addressSuggestionViewController.onSelect = { [weak self] suggestion in
            self?.applyAddressSuggestion(suggestion)
        }

        currencyPopover.behavior = .semitransient
        currencyPopover.animates = true
        currencyPopover.contentViewController = currencyViewController
        currencyViewController.onConvert = { [weak self] request in
            self?.runCurrencyConversion(request)
        }
        currencyViewController.onScanPage = { [weak self] in
            self?.scanPageCurrencyCommand(nil)
        }

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
        hardReloadButton.target = self
        hardReloadButton.action = #selector(hardReloadCommand(_:))
        privateButton.target = self
        privateButton.action = #selector(newPrivateTabCommand(_:))
        screenshotButton.target = self
        screenshotButton.action = #selector(screenshotTabCommand(_:))
        currencyButton.target = self
        currencyButton.action = #selector(showCurrencyConverterCommand(_:))
        parserButton.target = self
        parserButton.action = #selector(openParserCommand(_:))
        settingsButton.target = self
        settingsButton.action = #selector(showSettingsCommand(_:))

        browserContentView.addSubview(toolbarView)
        browserContentView.addSubview(webContainerView)

        [brandTitleField, backButton, forwardButton, homeButton, addressField, parserButton, reloadButton, hardReloadButton, privateButton, screenshotButton, currencyButton, settingsButton, progressIndicator].forEach {
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

            currencyButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -8),
            currencyButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            screenshotButton.trailingAnchor.constraint(equalTo: currencyButton.leadingAnchor, constant: -8),
            screenshotButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            privateButton.trailingAnchor.constraint(equalTo: screenshotButton.leadingAnchor, constant: -8),
            privateButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            hardReloadButton.trailingAnchor.constraint(equalTo: privateButton.leadingAnchor, constant: -8),
            hardReloadButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            reloadButton.trailingAnchor.constraint(equalTo: hardReloadButton.leadingAnchor, constant: -8),
            reloadButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            parserButton.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -8),
            parserButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            addressField.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: 12),
            addressField.trailingAnchor.constraint(equalTo: parserButton.leadingAnchor, constant: -12),
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
        if let webView = tab.webView as? BrowserWebView {
            webView.onConfigureContextMenu = { [weak self] webView, menu in
                self?.appendCurrencyConversionItem(to: menu, webView: webView)
            }
        }
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
        let wasShowingParser = oldTab.isShowingParser
        let parserSnapshot = oldTab.parserSnapshot
        let targetURL = oldTab.isShowingHome || oldTab.isShowingSettings || oldTab.isShowingParser ? nil : oldTab.url ?? oldTab.webView.url
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
        } else if wasShowingParser, let parserSnapshot {
            newTab.loadParserPage(snapshot: parserSnapshot, theme: preferences.theme, colorScheme: preferences.colorScheme, design: preferences.design)
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
        hideAddressSuggestions()
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
                favicon: tab.faviconImage,
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
            searchRegion: preferences.searchRegion,
            searchLanguage: preferences.searchLanguage,
            theme: preferences.theme,
            colorScheme: preferences.colorScheme,
            design: preferences.design,
            homeBackground: preferences.homeBackground,
            recentHistory: BrowserHistoryStore.shared.entries
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

    private func openParserTab(from sourceTab: BrowserTab) async {
        guard !sourceTab.isShowingHome && !sourceTab.isShowingSettings && !sourceTab.isShowingParser else {
            NSSound.beep()
            return
        }

        let snapshot = await PageParser.snapshot(
            from: sourceTab.webView,
            fallbackURL: sourceTab.url ?? sourceTab.webView.url,
            fallbackTitle: sourceTab.displayTitle
        )

        let tab = makeTab(profile: sourceTab.profile)
        tabs.append(tab)
        activeTabID = tab.id
        showActiveTab()
        renderTabs()
        tab.loadParserPage(
            snapshot: snapshot,
            theme: preferences.theme,
            colorScheme: preferences.colorScheme,
            design: preferences.design
        )
    }

    private func showSettings(in tab: BrowserTab, activeSection: SettingsSection = .overview) {
        tab.loadSettingsPage(
            preferences: preferences,
            history: BrowserHistoryStore.shared.entries,
            downloads: DownloadHistoryStore.shared.entries,
            performance: PerformanceMonitor.shared.snapshot(
                activeTabs: tabs.count,
                loadingTabs: tabs.filter { $0.webView.isLoading }.count
            ),
            theme: preferences.theme,
            activeSection: activeSection,
            defaultAppStatus: defaultAppStatusMessage
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

        let selectedRegion = components.queryItems?
            .first(where: { $0.name == "region" })?
            .value
            .flatMap(SearchRegion.init(identifier:))

        if let selectedRegion, selectedRegion != preferences.searchRegion {
            preferences.searchRegion = selectedRegion
        }

        let selectedLanguage = components.queryItems?
            .first(where: { $0.name == "language" })?
            .value
            .flatMap(SearchLanguage.init(identifier:))

        if let selectedLanguage, selectedLanguage != preferences.searchLanguage {
            preferences.searchLanguage = selectedLanguage
        }

        guard let query = components.queryItems?.first(where: { $0.name == "q" })?.value,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let targetURL = URLParser.url(
                from: query,
                searchEngine: selectedEngine ?? preferences.searchEngine,
                region: selectedRegion ?? preferences.searchRegion,
                language: selectedLanguage ?? preferences.searchLanguage
              ) else {
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
            let activeSection = queryItems
                .first(where: { $0.name == "section" })?
                .value
                .flatMap(SettingsSection.init(identifier:)) ?? .overview

            if let identifier = queryItems.first(where: { $0.name == "search" })?.value,
               let searchEngine = SearchEngine(identifier: identifier),
               searchEngine != preferences.searchEngine {
                preferences.searchEngine = searchEngine
            }

            if let identifier = queryItems.first(where: { $0.name == "region" })?.value,
               let searchRegion = SearchRegion(identifier: identifier),
               searchRegion != preferences.searchRegion {
                preferences.searchRegion = searchRegion
            }

            if let identifier = queryItems.first(where: { $0.name == "language" })?.value,
               let searchLanguage = SearchLanguage(identifier: identifier),
               searchLanguage != preferences.searchLanguage {
                preferences.searchLanguage = searchLanguage
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

            if let identifier = queryItems.first(where: { $0.name == "adblock" })?.value,
               let adBlockMode = AdBlockMode(identifier: identifier),
               adBlockMode != preferences.adBlockMode {
                preferences.adBlockMode = adBlockMode
            }

            if let identifier = queryItems.first(where: { $0.name == "currencySource" })?.value,
               let currencySource = CurrencyCode(rawValue: identifier),
               currencySource != preferences.defaultCurrencySource {
                preferences.defaultCurrencySource = currencySource
            }

            if let identifier = queryItems.first(where: { $0.name == "currencyTarget" })?.value,
               let currencyTarget = CurrencyCode(rawValue: identifier),
               currencyTarget != preferences.defaultCurrencyTarget {
                preferences.defaultCurrencyTarget = currencyTarget
            }

            showSettings(in: tab, activeSection: activeSection)
        case "open":
            guard let rawURL = queryItems.first(where: { $0.name == "url" })?.value,
                  let targetURL = URL(string: rawURL) else {
                showSettings(in: tab)
                return
            }

            load(targetURL, in: tab)
        case "clear-history":
            BrowserHistoryStore.shared.clear()
            showSettings(in: tab, activeSection: .history)
        case "clear-downloads":
            DownloadHistoryStore.shared.clear()
            showSettings(in: tab, activeSection: .downloads)
        case "default-browser":
            defaultAppStatusMessage = "Назначаю NorthStar браузером по умолчанию..."
            showSettings(in: tab, activeSection: .browser)
            DefaultAppManager.setAsDefaultBrowser { [weak self, weak tab] message in
                Task { @MainActor in
                    guard let self, let tab else { return }
                    self.defaultAppStatusMessage = message
                    self.showSettings(in: tab, activeSection: .browser)
                }
            }
        case "default-pdf":
            defaultAppStatusMessage = "Назначаю NorthStar приложением по умолчанию для PDF..."
            showSettings(in: tab, activeSection: .browser)
            DefaultAppManager.setAsDefaultPDFViewer { [weak self, weak tab] message in
                Task { @MainActor in
                    guard let self, let tab else { return }
                    self.defaultAppStatusMessage = message
                    self.showSettings(in: tab, activeSection: .browser)
                }
            }
        default:
            showSettings(in: tab)
        }
    }

    private func syncToolbar() {
        guard let tab = activeTab else {
            backButton.isEnabled = false
            forwardButton.isEnabled = false
            reloadButton.isEnabled = false
            hardReloadButton.isEnabled = false
            screenshotButton.isEnabled = false
            parserButton.isEnabled = false
            addressField.stringValue = ""
            progressIndicator.isHidden = true
            return
        }

        backButton.isEnabled = tab.webView.canGoBack
        forwardButton.isEnabled = tab.webView.canGoForward
        reloadButton.isEnabled = true
        hardReloadButton.isEnabled = true
        screenshotButton.isEnabled = !tab.webView.bounds.isEmpty
        parserButton.isEnabled = !tab.isShowingHome && !tab.isShowingSettings && !tab.isShowingParser

        let reloadSymbol = tab.webView.isLoading ? "xmark" : "arrow.clockwise"
        reloadButton.image = NSImage(systemSymbolName: reloadSymbol, accessibilityDescription: tab.webView.isLoading ? "Остановить" : "Обновить")
        reloadButton.toolTip = tab.webView.isLoading ? "Остановить" : "Обновить"

        if !isEditingAddress {
            if tab.isShowingHome {
                addressField.stringValue = ""
            } else if tab.isShowingSettings {
                addressField.stringValue = "northstar://settings"
            } else if tab.isShowingParser {
                addressField.stringValue = "northstar://parser"
            } else {
                addressField.stringValue = tab.url?.absoluteString ?? tab.webView.url?.absoluteString ?? ""
            }
        }

        progressIndicator.doubleValue = tab.progress
        progressIndicator.isHidden = tab.isShowingHome || tab.isShowingSettings || tab.isShowingParser || !tab.webView.isLoading || tab.progress >= 1

        if let profileIndex = NetworkProfile.allCases.firstIndex(of: tab.profile) {
            networkPopup.selectItem(at: profileIndex)
        }

        if let searchIndex = SearchEngine.allCases.firstIndex(of: preferences.searchEngine) {
            searchEnginePopup.selectItem(at: searchIndex)
        }

        view.window?.title = tab.profile.isPrivateMode ? "\(appName) - Приватно" : appName
    }

    private var isEditingAddress: Bool {
        view.window?.firstResponder === addressField.currentEditor()
    }

    private func shouldRecordLocalActivity(for tab: BrowserTab) -> Bool {
        !tab.profile.isPrivateMode && !tab.isShowingHome && !tab.isShowingSettings && !tab.isShowingParser
    }

    private func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }

    private func prepareDownload(_ download: WKDownload, from webView: WKWebView) {
        download.delegate = self

        let downloadID = ObjectIdentifier(download)
        if tab(for: webView)?.profile.isPrivateMode == true {
            privateDownloads.insert(downloadID)
        } else {
            privateDownloads.remove(downloadID)
        }
    }

    private func appendCurrencyConversionItem(to menu: NSMenu, webView: WKWebView) {
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        let item = NSMenuItem(
            title: "Конвертировать выделенную цену",
            action: #selector(convertSelectionCurrencyCommand(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = webView
        menu.addItem(item)

        let scanItem = NSMenuItem(
            title: "Найти цену на странице",
            action: #selector(scanPageCurrencyCommand(_:)),
            keyEquivalent: ""
        )
        scanItem.target = self
        scanItem.representedObject = webView
        menu.addItem(scanItem)
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

    private func showScreenshotError(_ error: Error?) {
        let alert = NSAlert()
        alert.messageText = "Не удалось скопировать скриншот"
        alert.informativeText = error?.localizedDescription ?? "Попробуйте ещё раз после загрузки вкладки."
        alert.alertStyle = .warning

        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func playScreenshotCaptureEffect() {
        guard !webContainerView.bounds.isEmpty else {
            playScreenshotSound()
            return
        }

        screenshotEffectView?.removeFromSuperview()
        playScreenshotSound()

        let overlay = NSView(frame: webContainerView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        overlay.alphaValue = 0

        let dimView = NSView(frame: overlay.bounds)
        dimView.autoresizingMask = [.width, .height]
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor
        dimView.alphaValue = 0

        let flashView = NSView(frame: overlay.bounds)
        flashView.autoresizingMask = [.width, .height]
        flashView.wantsLayer = true
        flashView.layer?.backgroundColor = NSColor.white.cgColor
        flashView.alphaValue = 0

        let ringSize = min(max(min(overlay.bounds.width, overlay.bounds.height) * 0.22, 96), 168)
        let ringView = NSView(frame: NSRect(
            x: overlay.bounds.midX - ringSize / 2,
            y: overlay.bounds.midY - ringSize / 2,
            width: ringSize,
            height: ringSize
        ))
        ringView.autoresizingMask = []
        ringView.wantsLayer = true
        ringView.layer?.cornerRadius = ringSize / 2
        ringView.layer?.borderWidth = 2
        ringView.layer?.borderColor = NSColor.white.withAlphaComponent(0.90).cgColor
        ringView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        ringView.alphaValue = 0

        overlay.addSubview(dimView)
        overlay.addSubview(flashView)
        overlay.addSubview(ringView)
        webContainerView.addSubview(overlay, positioned: .above, relativeTo: nil)
        screenshotEffectView = overlay

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.045
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = 1
            dimView.animator().alphaValue = 1
            flashView.animator().alphaValue = 0.86
            ringView.animator().alphaValue = 1
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dimView.animator().alphaValue = 0
                flashView.animator().alphaValue = 0
                ringView.animator().alphaValue = 0
            } completionHandler: {
                overlay.removeFromSuperview()
            }
        }
    }

    private func playScreenshotSound() {
        let soundURLs = [
            URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/begin_record.caf"),
            URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/acknowledgment_sent.caf")
        ]

        for url in soundURLs where FileManager.default.fileExists(atPath: url.path) {
            if let sound = NSSound(contentsOf: url, byReference: true) {
                screenshotSound = sound
                sound.volume = 0.78
                sound.play()
                return
            }
        }

        screenshotSound = NSSound(named: NSSound.Name("Tink"))
        screenshotSound?.play()
    }

    private func showCurrencyError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Конвертация валюты"
        alert.informativeText = message
        alert.alertStyle = .informational

        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension BrowserViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === addressField else { return }
        updateAddressSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === addressField else { return false }

        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            if activeAddressSuggestions.isEmpty {
                updateAddressSuggestions()
            }
            moveAddressSuggestionSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            if activeAddressSuggestions.isEmpty {
                updateAddressSuggestions()
            }
            moveAddressSuggestionSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if applySelectedAddressSuggestion() {
                return true
            }
            loadTypedAddress(control)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideAddressSuggestions()
            return true
        default:
            return false
        }
    }
}

extension BrowserViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let tab = tab(for: webView) {
            if shouldRecordLocalActivity(for: tab) {
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
        if shouldRecordLocalActivity(for: tab), let currentURL = tab.url ?? webView.url {
            tab.refreshFavicon()
            BrowserHistoryStore.shared.record(url: currentURL, title: tab.displayTitle)
            PerformanceMonitor.shared.finish(tabID: tab.id, url: currentURL, title: tab.displayTitle, status: .loaded)
            refreshSettingsTabs()
        }

        syncToolbar()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let tab = tab(for: webView) {
            tab.syncFromWebView()
            if shouldRecordLocalActivity(for: tab), let currentURL = tab.url ?? webView.url {
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
            if shouldRecordLocalActivity(for: tab), let currentURL = tab.url ?? webView.url {
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
        prepareDownload(download, from: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        prepareDownload(download, from: webView)
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
        let downloadID = ObjectIdentifier(download)

        if privateDownloads.contains(downloadID) {
            completionHandler(destinationURL)
            return
        }

        let id = DownloadHistoryStore.shared.start(
            fileName: destinationURL.lastPathComponent,
            sourceURL: response.url,
            destinationURL: destinationURL
        )
        activeDownloads[downloadID] = id
        refreshSettingsTabs()
        completionHandler(destinationURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let downloadID = ObjectIdentifier(download)
        privateDownloads.remove(downloadID)

        if let id = activeDownloads.removeValue(forKey: downloadID) {
            DownloadHistoryStore.shared.finish(id: id)
            refreshSettingsTabs()
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let downloadID = ObjectIdentifier(download)
        privateDownloads.remove(downloadID)

        if let id = activeDownloads.removeValue(forKey: downloadID) {
            DownloadHistoryStore.shared.fail(id: id, error: error.localizedDescription)
            refreshSettingsTabs()
        }
    }
}

@MainActor
private final class BrowserWebView: WKWebView {
    var onConfigureContextMenu: ((WKWebView, NSMenu) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        onConfigureContextMenu?(self, menu)
        return menu
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
    private(set) var faviconImage: NSImage? = NSImage(systemSymbolName: "sparkles", accessibilityDescription: appName)
    private(set) var isShowingHome = true
    private(set) var isShowingSettings = false
    private(set) var isShowingParser = false
    private(set) var parserSnapshot: PageParseSnapshot?
    private var observations: [NSKeyValueObservation] = []
    private var faviconTask: Task<Void, Never>?
    private var faviconCacheKey: String?

    var displayTitle: String {
        if isShowingSettings {
            return settingsTitle
        }

        if isShowingParser {
            return parserTitle
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
        webView = BrowserWebView(frame: .zero, configuration: profile.makeWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        bindWebViewState()
    }

    func loadHomePage(searchEngine: SearchEngine, searchRegion: SearchRegion, searchLanguage: SearchLanguage, theme: ThemeMode, colorScheme: ColorSchemeMode, design: DesignMode, homeBackground: HomeBackgroundMode, recentHistory: [BrowserHistoryEntry]) {
        isShowingHome = true
        isShowingSettings = false
        isShowingParser = false
        parserSnapshot = nil
        title = appName
        url = nil
        progress = 1
        faviconTask?.cancel()
        faviconCacheKey = nil
        let homeSymbol = profile.isPrivateMode ? "eye.slash" : "sparkles"
        faviconImage = NSImage(systemSymbolName: homeSymbol, accessibilityDescription: appName)
        notifyChanged()
        webView.loadHTMLString(
            HomePage.html(searchEngine: searchEngine, searchRegion: searchRegion, searchLanguage: searchLanguage, theme: theme, colorScheme: colorScheme, design: design, homeBackground: homeBackground, recentHistory: recentHistory),
            baseURL: nil
        )
    }

    func loadSettingsPage(preferences: AppPreferences, history: [BrowserHistoryEntry], downloads: [DownloadHistoryEntry], performance: PerformanceSnapshot, theme: ThemeMode, activeSection: SettingsSection, defaultAppStatus: String?) {
        isShowingHome = false
        isShowingSettings = true
        isShowingParser = false
        parserSnapshot = nil
        title = settingsTitle
        url = nil
        progress = 1
        faviconTask?.cancel()
        faviconCacheKey = nil
        faviconImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: settingsTitle)
        notifyChanged()
        webView.loadHTMLString(
            SettingsPage.html(preferences: preferences, history: history, downloads: downloads, performance: performance, theme: theme, activeSection: activeSection, defaultAppStatus: defaultAppStatus),
            baseURL: nil
        )
    }

    func loadParserPage(snapshot: PageParseSnapshot, theme: ThemeMode, colorScheme: ColorSchemeMode, design: DesignMode) {
        isShowingHome = false
        isShowingSettings = false
        isShowingParser = true
        parserSnapshot = snapshot
        title = parserTitle
        url = nil
        progress = 1
        faviconTask?.cancel()
        faviconCacheKey = nil
        faviconImage = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: parserTitle)
        notifyChanged()
        webView.loadHTMLString(
            ParserPage.html(snapshot: snapshot, theme: theme, colorScheme: colorScheme, design: design),
            baseURL: nil
        )
    }

    func load(_ url: URL) {
        isShowingHome = false
        isShowingSettings = false
        isShowingParser = false
        parserSnapshot = nil
        self.url = url
        title = Self.normalizedTitle(url.host(percentEncoded: false)) ?? "Загрузка"
        progress = 0
        updateFaviconFromCache(for: url)
        notifyChanged()
        webView.load(URLRequest(url: url))
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        faviconTask?.cancel()
        observations.removeAll()
    }

    func syncFromWebView() {
        if isShowingHome {
            title = appName
            progress = webView.isLoading ? webView.estimatedProgress : 1
        } else if isShowingSettings {
            title = settingsTitle
            progress = webView.isLoading ? webView.estimatedProgress : 1
        } else if isShowingParser {
            title = parserTitle
            progress = webView.isLoading ? webView.estimatedProgress : 1
        } else {
            url = webView.url ?? url
            title = Self.normalizedTitle(webView.title) ?? Self.normalizedTitle(url?.host(percentEncoded: false)) ?? "Новая вкладка"
            progress = webView.estimatedProgress
            updateFaviconFromCache(for: url)
        }

        notifyChanged()
    }

    func refreshFavicon() {
        guard !isShowingHome && !isShowingSettings,
              let pageURL = url ?? webView.url,
              let cacheKey = FaviconStore.cacheKey(for: pageURL, profile: profile) else {
            return
        }

        faviconCacheKey = cacheKey

        if let cachedImage = FaviconStore.shared.cachedImage(for: pageURL, profile: profile) {
            faviconTask?.cancel()
            faviconImage = cachedImage
            notifyChanged()
            return
        }

        faviconTask?.cancel()
        faviconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let declaredIconURL = await self.declaredFaviconURL(baseURL: pageURL)
            let image = await FaviconStore.shared.image(for: pageURL, declaredIconURL: declaredIconURL, profile: self.profile)
            guard !Task.isCancelled,
                  self.faviconCacheKey == cacheKey else {
                return
            }

            self.faviconImage = image
            self.notifyChanged()
        }
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
                    if !self.isShowingHome && !self.isShowingSettings && !self.isShowingParser {
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
                    } else if self.isShowingParser {
                        self.title = parserTitle
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

    private func updateFaviconFromCache(for pageURL: URL?) {
        guard let pageURL,
              let cacheKey = FaviconStore.cacheKey(for: pageURL, profile: profile) else {
            faviconCacheKey = nil
            faviconImage = nil
            faviconTask?.cancel()
            return
        }

        if faviconCacheKey == cacheKey {
            return
        }

        faviconCacheKey = cacheKey
        faviconTask?.cancel()
        faviconImage = FaviconStore.shared.cachedImage(for: pageURL, profile: profile)
    }

    private func declaredFaviconURL(baseURL: URL) async -> URL? {
        let script = """
        (() => {
          const links = Array.from(document.querySelectorAll('link[rel][href]'));
          const score = (link) => {
            const rel = String(link.rel || '').toLowerCase();
            const sizes = String(link.getAttribute('sizes') || '');
            if (rel.includes('apple-touch-icon')) return 4;
            if (sizes.includes('192') || sizes.includes('180') || sizes.includes('128')) return 3;
            if (rel.includes('icon')) return 2;
            return 0;
          };
          return links
            .map((link) => ({ href: link.href, score: score(link) }))
            .filter((item) => item.href && item.score > 0)
            .sort((a, b) => b.score - a.score)[0]?.href || '';
        })()
        """

        do {
            guard let result = try await webView.evaluateJavaScript(script) as? String,
                  !result.isEmpty else {
                return nil
            }

            return URL(string: result, relativeTo: baseURL)?.absoluteURL
        } catch {
            return nil
        }
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
private final class FaviconStore {
    static let shared = FaviconStore()

    private let maximumIconBytes = 1_048_576
    private var images: [String: NSImage] = [:]
    private var failedKeys: Set<String> = []
    private var inFlightTasks: [String: Task<NSImage?, Never>] = [:]

    static func cacheKey(for pageURL: URL, profile: NetworkProfile) -> String? {
        guard let host = pageURL.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return nil
        }

        return "\(profile.rawValue):\(host)"
    }

    func cachedImage(for pageURL: URL, profile: NetworkProfile) -> NSImage? {
        guard let key = Self.cacheKey(for: pageURL, profile: profile) else {
            return nil
        }

        return images[key]
    }

    func image(for pageURL: URL, declaredIconURL: URL?, profile: NetworkProfile) async -> NSImage? {
        guard let key = Self.cacheKey(for: pageURL, profile: profile) else {
            return nil
        }

        if let cachedImage = images[key] {
            return cachedImage
        }

        if failedKeys.contains(key) {
            return nil
        }

        if let existingTask = inFlightTasks[key] {
            return await existingTask.value
        }

        let candidates = Self.iconCandidates(for: pageURL, declaredIconURL: declaredIconURL, profile: profile)
        guard !candidates.isEmpty else {
            failedKeys.insert(key)
            return nil
        }

        let task = Task<NSImage?, Never> { [maximumIconBytes] in
            let session = URLSession(configuration: profile.faviconSessionConfiguration)
            for candidate in candidates {
                guard !Task.isCancelled else { return nil }
                if let image = await Self.fetchImage(from: candidate, session: session, maximumBytes: maximumIconBytes) {
                    return image
                }
            }

            return nil
        }

        inFlightTasks[key] = task
        let image = await task.value
        inFlightTasks[key] = nil

        if let image {
            images[key] = image
        } else {
            failedKeys.insert(key)
        }

        return image
    }

    private static func iconCandidates(for pageURL: URL, declaredIconURL: URL?, profile: NetworkProfile) -> [URL] {
        guard let scheme = pageURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = pageURL.host(percentEncoded: false), !host.isEmpty else {
            return []
        }

        let origin = "\(scheme)://\(host)"
        let baseCandidates = [
            declaredIconURL,
            URL(string: "/favicon.ico", relativeTo: URL(string: origin)),
            URL(string: "/apple-touch-icon.png", relativeTo: URL(string: origin)),
            URL(string: "/apple-touch-icon-precomposed.png", relativeTo: URL(string: origin))
        ]

        var seen: Set<String> = []
        return baseCandidates.compactMap { candidate in
            guard let iconURL = candidate?.absoluteURL,
                  let iconScheme = iconURL.scheme?.lowercased(),
                  ["http", "https"].contains(iconScheme),
                  NetworkPolicy.allows(iconURL, profile: profile),
                  !AdBlocker.shouldBlock(iconURL) else {
                return nil
            }

            let key = iconURL.absoluteString
            guard seen.insert(key).inserted else {
                return nil
            }

            return iconURL
        }
    }

    private static func fetchImage(from url: URL, session: URLSession, maximumBytes: Int) async -> NSImage? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 6)
        request.setValue(BrowserUserAgent.safari, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return nil
            }

            guard !data.isEmpty, data.count <= maximumBytes,
                  let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0 else {
                return nil
            }

            image.size = NSSize(width: 16, height: 16)
            return image
        } catch {
            return nil
        }
    }
}

private struct PageParseSnapshot: Codable {
    var capturedAt: String
    var url: String
    var title: String
    var description: String
    var language: String
    var canonicalURL: String
    var visibleText: String
    var textCharacters: Int
    var html: String
    var htmlCharacters: Int
    var htmlTruncated: Bool
    var headings: [PageParseHeading]
    var links: [PageParseLink]
    var images: [PageParseImage]
}

private struct PageParseHeading: Codable {
    var level: Int
    var text: String
}

private struct PageParseLink: Codable {
    var text: String
    var href: String
}

private struct PageParseImage: Codable {
    var alt: String
    var src: String
}

@MainActor
private enum PageParser {
    static func snapshot(from webView: WKWebView, fallbackURL: URL?, fallbackTitle: String) async -> PageParseSnapshot {
        do {
            if let json = try await webView.evaluateJavaScript(extractionScript) as? String,
               let data = json.data(using: .utf8) {
                let decoder = JSONDecoder()
                return try decoder.decode(PageParseSnapshot.self, from: data)
            }
        } catch {
            return fallbackSnapshot(url: fallbackURL, title: fallbackTitle)
        }

        return fallbackSnapshot(url: fallbackURL, title: fallbackTitle)
    }

    private static func fallbackSnapshot(url: URL?, title: String) -> PageParseSnapshot {
        PageParseSnapshot(
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            url: url?.absoluteString ?? "",
            title: title,
            description: "",
            language: "",
            canonicalURL: "",
            visibleText: "",
            textCharacters: 0,
            html: "",
            htmlCharacters: 0,
            htmlTruncated: false,
            headings: [],
            links: [],
            images: []
        )
    }

    private static let extractionScript = """
    (() => {
      const LIMITS = {
        text: 120000,
        html: 300000,
        headings: 180,
        links: 600,
        images: 260
      };
      const clean = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
      const cut = (value, limit) => {
        const text = String(value || '');
        return text.length > limit ? text.slice(0, limit) : text;
      };
      const visibleText = clean(document.body?.innerText || '');
      const fullHTML = document.documentElement?.outerHTML || '';
      const meta = (name) => document.querySelector(`meta[name="${name}"], meta[property="${name}"]`)?.content || '';
      const canonical = document.querySelector('link[rel="canonical"]')?.href || '';

      const headings = Array.from(document.querySelectorAll('h1,h2,h3'))
        .map((node) => ({ level: Number(node.tagName.slice(1)), text: clean(node.innerText || node.textContent) }))
        .filter((item) => item.text)
        .slice(0, LIMITS.headings);

      const seenLinks = new Set();
      const links = [];
      for (const anchor of document.querySelectorAll('a[href]')) {
        const href = anchor.href || '';
        if (!href || seenLinks.has(href)) continue;
        seenLinks.add(href);
        links.push({
          text: clean(anchor.innerText || anchor.getAttribute('aria-label') || anchor.title || href),
          href
        });
        if (links.length >= LIMITS.links) break;
      }

      const seenImages = new Set();
      const images = [];
      for (const image of document.querySelectorAll('img[src]')) {
        const src = image.currentSrc || image.src || '';
        if (!src || seenImages.has(src)) continue;
        seenImages.add(src);
        images.push({
          alt: clean(image.alt || image.getAttribute('aria-label') || ''),
          src
        });
        if (images.length >= LIMITS.images) break;
      }

      return JSON.stringify({
        capturedAt: new Date().toISOString(),
        url: location.href,
        title: clean(document.title),
        description: clean(meta('description') || meta('og:description')),
        language: document.documentElement?.lang || '',
        canonicalURL: canonical,
        visibleText: cut(visibleText, LIMITS.text),
        textCharacters: visibleText.length,
        html: cut(fullHTML, LIMITS.html),
        htmlCharacters: fullHTML.length,
        htmlTruncated: fullHTML.length > LIMITS.html,
        headings,
        links,
        images
      });
    })()
    """
}

private final class AppPreferences {
    static let shared = AppPreferences()
    static let didChangeNotification = Notification.Name("NorthStarPreferencesDidChange")

    var searchEngine: SearchEngine {
        didSet { saveAndNotify(key: Keys.searchEngine, value: searchEngine.rawValue) }
    }

    var searchRegion: SearchRegion {
        didSet { saveAndNotify(key: Keys.searchRegion, value: searchRegion.rawValue) }
    }

    var searchLanguage: SearchLanguage {
        didSet { saveAndNotify(key: Keys.searchLanguage, value: searchLanguage.rawValue) }
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

    var adBlockMode: AdBlockMode {
        didSet { saveAndNotify(key: Keys.adBlockMode, value: adBlockMode.rawValue) }
    }

    var defaultCurrencySource: CurrencyCode {
        didSet { saveAndNotify(key: Keys.defaultCurrencySource, value: defaultCurrencySource.rawValue) }
    }

    var defaultCurrencyTarget: CurrencyCode {
        didSet { saveAndNotify(key: Keys.defaultCurrencyTarget, value: defaultCurrencyTarget.rawValue) }
    }

    var currencyAPIKey: String {
        didSet { saveAndNotify(key: Keys.currencyAPIKey, value: currencyAPIKey) }
    }

    private enum Keys {
        static let searchEngine = "searchEngine"
        static let searchRegion = "searchRegion"
        static let searchLanguage = "searchLanguage"
        static let tabPlacement = "tabPlacement"
        static let theme = "theme"
        static let colorScheme = "colorScheme"
        static let design = "design"
        static let homeBackground = "homeBackground"
        static let adBlockMode = "adBlockMode"
        static let defaultCurrencySource = "defaultCurrencySource"
        static let defaultCurrencyTarget = "defaultCurrencyTarget"
        static let currencyAPIKey = "currencyAPIKey"
    }

    private let defaults = UserDefaults.standard

    private init() {
        searchEngine = SearchEngine(rawValue: defaults.integer(forKey: Keys.searchEngine)) ?? .duckDuckGo
        searchRegion = SearchRegion(rawValue: defaults.integer(forKey: Keys.searchRegion)) ?? .automatic
        searchLanguage = SearchLanguage(rawValue: defaults.integer(forKey: Keys.searchLanguage)) ?? .automatic
        let savedTabPlacement = defaults.object(forKey: Keys.tabPlacement) as? Int
        tabPlacement = savedTabPlacement.flatMap(TabPlacement.init(rawValue:)) ?? .top
        theme = ThemeMode(rawValue: defaults.integer(forKey: Keys.theme)) ?? .system
        colorScheme = ColorSchemeMode(rawValue: defaults.integer(forKey: Keys.colorScheme)) ?? .aurora
        design = DesignMode(rawValue: defaults.integer(forKey: Keys.design)) ?? .balanced
        homeBackground = HomeBackgroundMode(rawValue: defaults.integer(forKey: Keys.homeBackground)) ?? .gradient
        let savedAdBlockMode = defaults.object(forKey: Keys.adBlockMode) as? Int
        adBlockMode = savedAdBlockMode.flatMap(AdBlockMode.init(rawValue:)) ?? .strict
        defaultCurrencySource = Self.currencyCode(for: Keys.defaultCurrencySource, defaults: defaults, fallback: .pln)
        defaultCurrencyTarget = Self.currencyCode(for: Keys.defaultCurrencyTarget, defaults: defaults, fallback: .usd)
        currencyAPIKey = defaults.string(forKey: Keys.currencyAPIKey) ?? ""
    }

    private func saveAndNotify(key: String, value: Int) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func saveAndNotify(key: String, value: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func currencyCode(for key: String, defaults: UserDefaults, fallback: CurrencyCode) -> CurrencyCode {
        guard let value = defaults.string(forKey: key),
              let code = CurrencyCode(rawValue: value) else {
            return fallback
        }

        return code
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

private enum AdBlockMode: Int, CaseIterable {
    case compatible
    case strict

    var title: String {
        switch self {
        case .compatible:
            return "Совместимая"
        case .strict:
            return "Строгая"
        }
    }

    var identifier: String {
        switch self {
        case .compatible:
            return "compatible"
        case .strict:
            return "strict"
        }
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = mode
    }
}

private enum SearchRegion: Int, CaseIterable {
    case automatic
    case poland
    case unitedStates
    case unitedKingdom
    case germany
    case france
    case spain
    case ukraine
    case russia

    var title: String {
        switch self {
        case .automatic:
            return "Авто-регион"
        case .poland:
            return "Польша"
        case .unitedStates:
            return "США"
        case .unitedKingdom:
            return "Великобритания"
        case .germany:
            return "Германия"
        case .france:
            return "Франция"
        case .spain:
            return "Испания"
        case .ukraine:
            return "Украина"
        case .russia:
            return "Россия"
        }
    }

    var identifier: String {
        switch self {
        case .automatic:
            return "auto"
        case .poland:
            return "pl"
        case .unitedStates:
            return "us"
        case .unitedKingdom:
            return "gb"
        case .germany:
            return "de"
        case .france:
            return "fr"
        case .spain:
            return "es"
        case .ukraine:
            return "ua"
        case .russia:
            return "ru"
        }
    }

    var countryCode: String? {
        switch self {
        case .automatic:
            return nil
        case .poland:
            return "PL"
        case .unitedStates:
            return "US"
        case .unitedKingdom:
            return "GB"
        case .germany:
            return "DE"
        case .france:
            return "FR"
        case .spain:
            return "ES"
        case .ukraine:
            return "UA"
        case .russia:
            return "RU"
        }
    }

    var defaultLanguageCode: String? {
        switch self {
        case .automatic:
            return nil
        case .poland:
            return "pl"
        case .unitedStates, .unitedKingdom:
            return "en"
        case .germany:
            return "de"
        case .france:
            return "fr"
        case .spain:
            return "es"
        case .ukraine:
            return "uk"
        case .russia:
            return "ru"
        }
    }

    var duckDuckGoRegion: String? {
        switch self {
        case .automatic:
            return nil
        case .poland:
            return "pl-pl"
        case .unitedStates:
            return "us-en"
        case .unitedKingdom:
            return "uk-en"
        case .germany:
            return "de-de"
        case .france:
            return "fr-fr"
        case .spain:
            return "es-es"
        case .ukraine:
            return "ua-uk"
        case .russia:
            return "ru-ru"
        }
    }

    var googleCountryRestriction: String? {
        countryCode.map { "country\($0)" }
    }

    var yandexRegionID: String? {
        switch self {
        case .russia:
            return "225"
        case .ukraine:
            return "187"
        case .automatic, .poland, .unitedStates, .unitedKingdom, .germany, .france, .spain:
            return nil
        }
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let region = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = region
    }
}

private enum SearchLanguage: Int, CaseIterable {
    case automatic
    case polish
    case russian
    case english
    case german
    case french
    case spanish
    case ukrainian

    var title: String {
        switch self {
        case .automatic:
            return "Авто-язык"
        case .polish:
            return "Польский"
        case .russian:
            return "Русский"
        case .english:
            return "Английский"
        case .german:
            return "Немецкий"
        case .french:
            return "Французский"
        case .spanish:
            return "Испанский"
        case .ukrainian:
            return "Украинский"
        }
    }

    var identifier: String {
        switch self {
        case .automatic:
            return "auto"
        case .polish:
            return "pl"
        case .russian:
            return "ru"
        case .english:
            return "en"
        case .german:
            return "de"
        case .french:
            return "fr"
        case .spanish:
            return "es"
        case .ukrainian:
            return "uk"
        }
    }

    var code: String? {
        self == .automatic ? nil : identifier
    }

    var defaultRegion: SearchRegion? {
        switch self {
        case .automatic:
            return nil
        case .polish:
            return .poland
        case .russian:
            return .russia
        case .english:
            return .unitedStates
        case .german:
            return .germany
        case .french:
            return .france
        case .spanish:
            return .spain
        case .ukrainian:
            return .ukraine
        }
    }

    var googleLanguageRestriction: String? {
        code.map { "lang_\($0)" }
    }

    func interfaceLocale(region: SearchRegion) -> String? {
        guard let code else { return nil }
        let countryCode = region.countryCode ?? defaultRegion?.countryCode

        if let countryCode {
            return "\(code)-\(countryCode)"
        }

        return code
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let language = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = language
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

    func searchURL(for query: String, region: SearchRegion, language: SearchLanguage) -> URL? {
        switch self {
        case .duckDuckGo:
            var queryItems = [URLQueryItem(name: "q", value: query)]
            if let duckRegion = region.duckDuckGoRegion ?? language.defaultRegion?.duckDuckGoRegion {
                queryItems.append(URLQueryItem(name: "kl", value: duckRegion))
            }

            return makeSearchURL(host: "duckduckgo.com", path: "/", queryItems: queryItems)
        case .google:
            var queryItems = [URLQueryItem(name: "q", value: query)]
            if let countryCode = region.countryCode?.lowercased() {
                queryItems.append(URLQueryItem(name: "gl", value: countryCode))
            }
            if let countryRestriction = region.googleCountryRestriction {
                queryItems.append(URLQueryItem(name: "cr", value: countryRestriction))
            }
            if let languageCode = language.code {
                queryItems.append(URLQueryItem(name: "hl", value: languageCode))
            }
            if let languageRestriction = language.googleLanguageRestriction {
                queryItems.append(URLQueryItem(name: "lr", value: languageRestriction))
            }

            return makeSearchURL(host: "www.google.com", path: "/search", queryItems: queryItems)
        case .yandex:
            var queryItems = [URLQueryItem(name: "text", value: query)]
            if let languageCode = language.code {
                queryItems.append(URLQueryItem(name: "lang", value: languageCode))
            }
            if let regionID = region.yandexRegionID {
                queryItems.append(URLQueryItem(name: "lr", value: regionID))
            }

            return makeSearchURL(host: "yandex.com", path: "/search/", queryItems: queryItems)
        case .brave:
            var queryItems = [URLQueryItem(name: "q", value: query)]
            let marketRegion = region == .automatic ? language.defaultRegion : region
            if let countryCode = marketRegion?.countryCode?.lowercased() {
                queryItems.append(URLQueryItem(name: "country", value: countryCode))
            }
            if let languageCode = language.code {
                queryItems.append(URLQueryItem(name: "search_lang", value: languageCode))
            }
            if let locale = language.interfaceLocale(region: region) {
                queryItems.append(URLQueryItem(name: "ui_lang", value: locale))
            }

            return makeSearchURL(host: "search.brave.com", path: "/search", queryItems: queryItems)
        case .bing:
            var queryItems = [URLQueryItem(name: "q", value: query)]
            if let market = bingMarket(region: region, language: language) {
                queryItems.append(URLQueryItem(name: "mkt", value: market))
            }
            if let languageCode = language.code {
                queryItems.append(URLQueryItem(name: "setLang", value: languageCode))
            }

            return makeSearchURL(host: "www.bing.com", path: "/search", queryItems: queryItems)
        case .ecosia:
            return makeSearchURL(host: "www.ecosia.org", path: "/search", queryItems: [URLQueryItem(name: "q", value: query)])
        case .startpage:
            return makeSearchURL(host: "www.startpage.com", path: "/sp/search", queryItems: [URLQueryItem(name: "query", value: query)])
        }
    }

    private func makeSearchURL(host: String, path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = queryItems
        return components.url
    }

    private func bingMarket(region: SearchRegion, language: SearchLanguage) -> String? {
        let marketRegion = region == .automatic ? language.defaultRegion : region
        guard let countryCode = marketRegion?.countryCode,
              let marketLanguage = marketRegion?.defaultLanguageCode ?? language.code else {
            return nil
        }

        return "\(marketLanguage)-\(countryCode)"
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

    var isPrivateMode: Bool {
        switch self {
        case .privateBrowsing, .tor:
            return true
        case .system, .localhost:
            return false
        }
    }

    @MainActor
    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        AdBlocker.install(in: configuration, mode: AppPreferences.shared.adBlockMode)

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

    var faviconSessionConfiguration: URLSessionConfiguration {
        let configuration: URLSessionConfiguration

        switch self {
        case .system:
            configuration = .default
        case .privateBrowsing, .localhost:
            configuration = .ephemeral
        case .tor:
            configuration = .ephemeral
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable as String: true,
                kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
                kCFNetworkProxiesSOCKSPort as String: 9050
            ]
        }

        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 0)
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        return configuration
    }
}

private enum BrowserUserAgent {
    static let applicationName = "Version/18.5 Safari/605.1.15"
    static let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(applicationName)"
}

private enum DefaultAppManager {
    static func setAsDefaultBrowser(completion: @escaping (String) -> Void) {
        let appURL = Bundle.main.bundleURL
        registerApplication(at: appURL)

        let schemes = ["http", "https"]
        let group = DispatchGroup()
        let lock = NSLock()
        var errors: [String] = []

        for scheme in schemes {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
                if let error {
                    lock.lock()
                    errors.append("\(scheme): \(error.localizedDescription)")
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if errors.isEmpty {
                completion("NorthStar назначен браузером по умолчанию для http и https.")
            } else {
                completion("Не удалось назначить браузер по умолчанию: \(errors.joined(separator: "; "))")
            }
        }
    }

    static func setAsDefaultPDFViewer(completion: @escaping (String) -> Void) {
        let appURL = Bundle.main.bundleURL
        registerApplication(at: appURL)

        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .pdf) { error in
            DispatchQueue.main.async {
                if let error {
                    completion("Не удалось назначить NorthStar для PDF: \(error.localizedDescription)")
                } else {
                    completion("NorthStar назначен приложением по умолчанию для PDF.")
                }
            }
        }
    }

    private static func registerApplication(at appURL: URL) {
        _ = LSRegisterURL(appURL as CFURL, true)
    }
}

private enum AdBlocker {
    private static func contentRuleIdentifier(for mode: AdBlockMode) -> String {
        "NorthStarAdBlocker.\(mode.identifier).v4"
    }

    private static let blockedHostSuffixes = [
        "2mdn.net",
        "adnami.io",
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
        "buysellads.com",
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
        "lushihdt.com",
        "media.net",
        "mgid.com",
        "moatads.com",
        "nitropay.com",
        "openx.net",
        "outbrain.com",
        "playwire.com",
        "pubmatic.com",
        "quantserve.com",
        "rubiconproject.com",
        "scorecardresearch.com",
        "servedby-buysellads.com",
        "smartadserver.com",
        "snigelweb.com",
        "taboola.com",
        "venatus.com",
        "venatusmedia.com",
        "yieldmo.com"
    ]

    private static let blockedURLFragments = [
        "/adserver/",
        "/ads/",
        "/advert/",
        "/banner/",
        "/banner-",
        "/banners/",
        "/gampad/",
        "/pagead/",
        "adservice.",
        "adunit",
        "adsystem",
        "adsby",
        "googleads",
        "lushihdt",
        "prebid",
        "prosper",
        "venatus",
        "vast?"
    ]

    private static let compatibleAllowedHostSuffixes = [
        "consensu.org",
        "google-analytics.com",
        "googletagmanager.com",
        "quantserve.com",
        "scorecardresearch.com"
    ]

    private static let compatibleBlockedURLFragments = [
        "/adserver/",
        "/ads/",
        "/advert/",
        "/banner/",
        "/banners/",
        "/gampad/",
        "/pagead/",
        "adservice.",
        "adunit",
        "adsystem",
        "adsby",
        "googleads",
        "lushihdt",
        "prebid",
        "prosper",
        "venatus",
        "vast?"
    ]

    static func shouldBlock(_ url: URL) -> Bool {
        shouldBlock(url, mode: AppPreferences.shared.adBlockMode)
    }

    static func shouldBlock(_ url: URL, mode: AdBlockMode) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return false
        }

        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        if mode == .compatible,
           compatibleAllowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return false
        }

        if blockedHostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return true
        }

        let absoluteString = url.absoluteString.lowercased()
        let fragments = mode == .compatible ? compatibleBlockedURLFragments : blockedURLFragments
        return fragments.contains { absoluteString.contains($0) }
    }

    @MainActor
    static func install(in configuration: WKWebViewConfiguration, mode: AdBlockMode) {
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(source: script(for: mode), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController = userContentController

        guard let store = WKContentRuleListStore.default() else {
            return
        }

        let identifier = contentRuleIdentifier(for: mode)
        store.lookUpContentRuleList(forIdentifier: identifier) { existingList, _ in
            if let existingList {
                DispatchQueue.main.async {
                    userContentController.add(existingList)
                }
                return
            }

            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: contentRules(for: mode)) { compiledList, _ in
                guard let compiledList else { return }
                DispatchQueue.main.async {
                    userContentController.add(compiledList)
                }
            }
        }
    }

    private static func contentRules(for mode: AdBlockMode) -> String {
        switch mode {
        case .compatible:
            return compatibleContentRules
        case .strict:
            return strictContentRules
        }
    }

    private static func script(for mode: AdBlockMode) -> String {
        switch mode {
        case .compatible:
            return compatibleScript
        case .strict:
            return strictScript
        }
    }

    private static let compatibleContentRules = """
    [
      { "trigger": { "url-filter": ".*2mdn\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adnami\\\\.io.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adform\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adnxs\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adsafeprotected\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adsrvr\\\\.org.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adservice\\\\.google\\\\..*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*advertising\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*amazon-adsystem\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*appnexus\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*bidswitch\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*buysellads\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*casalemedia\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*criteo\\\\.(com|net).*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*doubleclick\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*googlesyndication\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*googletagservices\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*imasdk\\\\.googleapis\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*lushihdt\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*media\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*mgid\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*moatads\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*nitropay\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*openx\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*outbrain\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*playwire\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*pubmatic\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*rubiconproject\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*servedby-buysellads\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*smartadserver\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*snigelweb\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*taboola\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*venatus(media)?\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*yieldmo\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*(/adserver/|/ads/|/advert/|/banner/|/banners/|/gampad/|/pagead/|adunit|adsby|googleads|lushihdt|prebid|prosper|venatus|vast\\\\?).*" }, "action": { "type": "block" } }
    ]
    """

    private static let strictContentRules = """
    [
      { "trigger": { "url-filter": ".*2mdn\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adnami\\\\.io.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adform\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adnxs\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adsafeprotected\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adsrvr\\\\.org.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*adservice\\\\.google\\\\..*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*advertising\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*amazon-adsystem\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*appnexus\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*bidswitch\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*buysellads\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*casalemedia\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*consensu\\\\.org.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*criteo\\\\.(com|net).*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*doubleclick\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*googlesyndication\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*googletag(manager|services)\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*google-analytics\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*imasdk\\\\.googleapis\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*lushihdt\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*media\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*mgid\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*moatads\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*nitropay\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*openx\\\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*outbrain\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*playwire\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*pubmatic\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*quantserve\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*rubiconproject\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*scorecardresearch\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*servedby-buysellads\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*smartadserver\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*snigelweb\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*taboola\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*venatus(media)?\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*yieldmo\\\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*(/adserver/|/ads/|/advert/|/banner/|/banners/|/gampad/|/pagead/|adunit|adsby|googleads|lushihdt|prebid|prosper|venatus|vast\\\\?).*" }, "action": { "type": "block" } }
    ]
    """

    private static let compatibleScript = adCleanupScript(removesConsent: false)
    private static let strictScript = adCleanupScript(removesConsent: true)

    private static func adCleanupScript(removesConsent: Bool) -> String {
        let consentSelectors = removesConsent ? """
        ".fc-consent-root",
        ".qc-cmp2-container",
        ".sp_message_container",
        "#onetrust-consent-sdk",
        "[id*='consent']",
        "[class*='consent']",
        "[class*='cmp-']",
        "[class*='cookie-banner']",
        """ : ""

        return """
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
            ".ads-padding",
            ".banner-ad",
            ".google-auto-placed",
            ".nitro-ad",
            ".nitro-ad-container",
            "[aria-label='Advertisement']",
            "[class*=' ad-']",
            "[class*=' ad_']",
            "[class*=' ads']",
            "[class*='ad-container']",
            "[class*='ad-wrapper']",
            "[class*='ad_slot']",
            "[class*='ads-padding']",
            "[class*='advert']",
            "[class*='banner-ad']",
            "[class*='nitro']",
            "[data-ad]",
            "[data-ad-client]",
            "[data-ad-slot]",
            "[data-ad-unit]",
            "[data-adunit]",
            "[data-google-query-id]",
            "[id*='ad-']",
            "[id*='ad_']",
            "[id*='ads']",
            "[id*='advert']",
            "[id*='banner-ad']",
            "[id*='nitro']",
            "a[href*='lushihdt.com']",
            "a[href*='venatus']",
            "iframe[src*='2mdn.net']",
            "iframe[src*='adservice.google']",
            "iframe[src*='doubleclick.net']",
            "iframe[src*='googlesyndication.com']",
            "iframe[src*='imasdk.googleapis.com']",
            "iframe[src*='nitropay.com']",
            "iframe[src*='venatus']",
            "img[src*='2mdn.net']",
            "img[src*='doubleclick.net']",
            "img[src*='googlesyndication.com']",
            "img[src*='venatus']",
            "ins.adsbygoogle",
        \(consentSelectors)
            "script[src*='venatus']"
          ];
          const blockedFragments = [
            "2mdn.net",
            "adform.net",
            "adnami.io",
            "adnxs.com",
            "adsafeprotected.com",
            "adsrvr.org",
            "adservice.google.",
            "advertising.com",
            "amazon-adsystem.com",
            "appnexus.com",
            "bidswitch.net",
            "buysellads.com",
            "casalemedia.com",
            "criteo.com",
            "criteo.net",
            "doubleclick.net",
            "googlesyndication.com",
            "googletagmanager.com",
            "googletagservices.com",
            "google-analytics.com",
            "googleads",
            "imasdk.googleapis.com",
            "lushihdt.com",
            "media.net",
            "mgid.com",
            "moatads.com",
            "nitropay.com",
            "openx.net",
            "outbrain.com",
            "pagead/",
            "playwire.com",
            "prebid",
            "prosper",
            "pubmatic.com",
            "rubiconproject.com",
            "scorecardresearch.com",
            "servedby-buysellads.com",
            "smartadserver.com",
            "snigelweb.com",
            "taboola.com",
            "venatus",
            "wargaming",
            "world of tanks",
            "worldoftanks",
            "yieldmo.com"
          ];
          const promoTextFragments = [
            "play now for free",
            "advertisement",
            "reklama"
          ];
          const selectorText = selectors.join(",");
          const largeTags = new Set(["BODY", "HTML", "MAIN", "NAV", "HEADER"]);
          const removableTags = new Set(["IFRAME", "IMG", "SCRIPT", "LINK", "SOURCE", "VIDEO", "INS"]);
          const textValue = element => [
            element.id,
            element.className,
            element.getAttribute && element.getAttribute("aria-label"),
            element.getAttribute && element.getAttribute("alt"),
            element.getAttribute && element.getAttribute("href"),
            element.getAttribute && element.getAttribute("src"),
            element.getAttribute && element.getAttribute("srcset"),
            element.getAttribute && element.getAttribute("style"),
            element.textContent
          ].join(" ").toLowerCase();
          const resourceValue = element => [
            element.id,
            element.className,
            element.currentSrc,
            element.src,
            element.href,
            element.getAttribute && element.getAttribute("href"),
            element.getAttribute && element.getAttribute("src"),
            element.getAttribute && element.getAttribute("srcset"),
            element.getAttribute && element.getAttribute("style")
          ].join(" ").toLowerCase();
          const hasAdSignal = element => {
            const value = textValue(element);
            return blockedFragments.some(fragment => value.includes(fragment)) || promoTextFragments.some(fragment => value.includes(fragment));
          };
          const hasResourceAdSignal = element => {
            const value = resourceValue(element);
            return blockedFragments.some(fragment => value.includes(fragment));
          };
          const isPageContainer = element => {
            if (!element || largeTags.has(element.tagName)) return true;
            const rect = element.getBoundingClientRect();
            return rect.width > window.innerWidth * 0.9 && rect.height > window.innerHeight * 0.7;
          };
          const targetFor = element => {
            let node = element;
            for (let depth = 0; node && depth < 5; depth += 1, node = node.parentElement) {
              if (!isPageContainer(node) && hasAdSignal(node)) return node;
            }
            return isPageContainer(element) ? null : element;
          };
          const hide = element => {
            element.style.setProperty("display", "none", "important");
            element.style.setProperty("visibility", "hidden", "important");
            element.style.setProperty("opacity", "0", "important");
            element.style.setProperty("pointer-events", "none", "important");
            element.style.setProperty("max-height", "0", "important");
            element.style.setProperty("overflow", "hidden", "important");
          };
          const removeElement = element => {
            const target = targetFor(element);
            if (target && removableTags.has(target.tagName)) {
              target.remove();
            } else if (target) {
              hide(target);
            } else {
              hide(element);
            }
          };
          const hideElement = element => {
            const target = targetFor(element);
            hide(target || element);
          };
          const removeResource = element => {
            if (removableTags.has(element.tagName)) {
              element.remove();
            } else {
              hide(element);
            }
          };
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
              document.querySelectorAll(selectorText).forEach(hideElement);
            } catch (_) {}
            document.querySelectorAll("iframe,img,script,link,source,video,ins").forEach(element => {
              if (hasResourceAdSignal(element)) removeResource(element);
            });
            document.querySelectorAll("a,picture,div,section,aside").forEach(element => {
              if (hasAdSignal(element)) removeElement(element);
            });
          };
          const schedule = (() => {
            let pending = false;
            return () => {
              if (pending) return;
              pending = true;
              requestAnimationFrame(() => {
                pending = false;
                removeMatches();
              });
            };
          })();
          const start = () => {
            removeMatches();
            const observer = new MutationObserver(schedule);
            observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["src", "href", "class", "id", "style"] });
            setTimeout(removeMatches, 500);
            setTimeout(removeMatches, 1500);
            setTimeout(removeMatches, 3000);
          };
          if (document.documentElement) {
            start();
          } else {
            document.addEventListener("DOMContentLoaded", start, { once: true });
          }
        })();
        """
    }
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

private enum CurrencyCode: String, CaseIterable {
    case pln = "PLN"
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case uah = "UAH"
    case rub = "RUB"
    case chf = "CHF"
    case czk = "CZK"
    case sek = "SEK"
    case nok = "NOK"
    case dkk = "DKK"
    case cad = "CAD"
    case aud = "AUD"
    case jpy = "JPY"

    var title: String {
        switch self {
        case .pln: return "PLN - польский злотый"
        case .usd: return "USD - доллар США"
        case .eur: return "EUR - евро"
        case .gbp: return "GBP - фунт"
        case .uah: return "UAH - гривна"
        case .rub: return "RUB - рубль"
        case .chf: return "CHF - франк"
        case .czk: return "CZK - чешская крона"
        case .sek: return "SEK - шведская крона"
        case .nok: return "NOK - норвежская крона"
        case .dkk: return "DKK - датская крона"
        case .cad: return "CAD - канадский доллар"
        case .aud: return "AUD - австралийский доллар"
        case .jpy: return "JPY - иена"
        }
    }
}

private struct CurrencyAmount {
    let amount: Double
    let currency: CurrencyCode
}

private struct CurrencyConversionRequest {
    let amount: Double
    let source: CurrencyCode
    let target: CurrencyCode
}

private struct CurrencyConversionResult {
    let amount: Double
    let source: CurrencyCode
    let target: CurrencyCode
    let rate: Double
    let convertedAmount: Double
    let updatedAt: String?
}

private enum CurrencyConversionError: LocalizedError {
    case invalidURL
    case api(String)
    case missingResult

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Не удалось собрать запрос к ExchangeRate-API."
        case .api(let message):
            return "ExchangeRate-API: \(message)"
        case .missingResult:
            return "API не вернул результат конвертации."
        }
    }
}

private enum CurrencyScanError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Не нашёл цену с валютой на видимой части страницы."
        }
    }
}

private enum CurrencyConverterService {
    private struct PairResponse: Decodable {
        let result: String
        let baseCode: String?
        let targetCode: String?
        let conversionRate: Double?
        let conversionResult: Double?
        let timeLastUpdateUTC: String?
        let errorType: String?

        private enum CodingKeys: String, CodingKey {
            case result
            case baseCode = "base_code"
            case targetCode = "target_code"
            case conversionRate = "conversion_rate"
            case conversionResult = "conversion_result"
            case timeLastUpdateUTC = "time_last_update_utc"
            case errorType = "error-type"
        }
    }

    static func convert(amount: Double, source: CurrencyCode, target: CurrencyCode, apiKey: String) async throws -> CurrencyConversionResult {
        let amountText = Self.apiAmountFormatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        guard let url = URL(string: "https://v6.exchangerate-api.com/v6/\(apiKey)/pair/\(source.rawValue)/\(target.rawValue)/\(amountText)") else {
            throw CurrencyConversionError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(PairResponse.self, from: data)

        guard response.result == "success" else {
            throw CurrencyConversionError.api(response.errorType ?? response.result)
        }

        guard let rate = response.conversionRate,
              let convertedAmount = response.conversionResult else {
            throw CurrencyConversionError.missingResult
        }

        return CurrencyConversionResult(
            amount: amount,
            source: source,
            target: target,
            rate: rate,
            convertedAmount: convertedAmount,
            updatedAt: response.timeLastUpdateUTC
        )
    }

    private static let apiAmountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false
        return formatter
    }()
}

private enum CurrencyAmountParser {
    static func parse(_ text: String, defaultCurrency: CurrencyCode) -> CurrencyAmount? {
        guard let amount = number(from: text) else { return nil }
        return CurrencyAmount(amount: amount, currency: detectedCurrency(in: text) ?? defaultCurrency)
    }

    static func bestCandidate(in fragments: [String], defaultCurrency: CurrencyCode) -> CurrencyAmount? {
        let candidates = fragments.compactMap { fragment -> CurrencyAmount? in
            guard let amount = parse(fragment, defaultCurrency: defaultCurrency),
                  amount.amount > 0 else {
                return nil
            }

            return amount
        }

        return candidates
            .filter { $0.amount < 1_000_000_000 }
            .max { lhs, rhs in
                lhs.amount < rhs.amount
            }
    }

    static func number(from text: String) -> Double? {
        let pattern = #"[0-9][0-9\s\u{00A0}.,]*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }

        let rawNumber = String(text[range])
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = rawNumber.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return nil }

        let decimalSeparator = Self.decimalSeparator(in: compact)
        let normalized = compact.enumerated().compactMap { index, character -> Character? in
            if character.isNumber {
                return character
            }

            if let decimalSeparator,
               character == decimalSeparator,
               compact.index(compact.startIndex, offsetBy: index) == compact.lastIndex(of: decimalSeparator) {
                return "."
            }

            return nil
        }

        return Double(String(normalized))
    }

    private static func detectedCurrency(in text: String) -> CurrencyCode? {
        let lowercased = text.lowercased()
        let matches: [(CurrencyCode, [String])] = [
            (.pln, ["pln", "zł", "zl"]),
            (.usd, ["usd", "us$", "$"]),
            (.eur, ["eur", "€"]),
            (.gbp, ["gbp", "£"]),
            (.uah, ["uah", "грн", "₴"]),
            (.rub, ["rub", "руб", "₽"]),
            (.chf, ["chf"]),
            (.czk, ["czk", "kč", "kc"]),
            (.sek, ["sek"]),
            (.nok, ["nok"]),
            (.dkk, ["dkk"]),
            (.cad, ["cad"]),
            (.aud, ["aud"]),
            (.jpy, ["jpy", "¥"])
        ]

        return matches.first { _, tokens in
            tokens.contains { lowercased.contains($0) }
        }?.0
    }

    private static func decimalSeparator(in text: String) -> Character? {
        let comma = text.lastIndex(of: ",")
        let dot = text.lastIndex(of: ".")

        if let comma, let dot {
            return comma > dot ? "," : "."
        }

        if let comma {
            return isLikelyDecimalSeparator(at: comma, in: text) ? "," : nil
        }

        if let dot {
            return isLikelyDecimalSeparator(at: dot, in: text) ? "." : nil
        }

        return nil
    }

    private static func isLikelyDecimalSeparator(at index: String.Index, in text: String) -> Bool {
        let digitsAfter = text[text.index(after: index)...].filter(\.isNumber).count
        return (1...2).contains(digitsAfter)
    }
}

private struct AddressSuggestion {
    let title: String
    let detail: String
    let input: String
    let url: URL?
    let symbolName: String
    let identity: String

    init(title: String, detail: String, input: String, url: URL?, symbolName: String, identity: String? = nil) {
        self.title = title
        self.detail = detail
        self.input = input
        self.url = url
        self.symbolName = symbolName
        self.identity = identity ?? url?.absoluteString ?? input.lowercased()
    }

    static func displayText(for url: URL) -> String {
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            let path = url.path == "/" ? "" : url.path
            return "\(host)\(path)"
        }

        return url.absoluteString
    }
}

@MainActor
private final class AddressSuggestionViewController: NSViewController {
    var onSelect: ((AddressSuggestion) -> Void)?

    private let stackView = NSStackView()
    private let horizontalInset: CGFloat = 8
    private let rowHeight: CGFloat = 52

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.32).cgColor

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: horizontalInset, bottom: 8, right: horizontalInset)
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func update(suggestions: [AddressSuggestion], selectedIndex: Int?, width: CGFloat) {
        let contentWidth = max(360, min(560, width))
        let rowWidth = max(1, contentWidth - horizontalInset * 2)

        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, suggestion) in suggestions.enumerated() {
            let row = AddressSuggestionRowView()
            row.configure(suggestion: suggestion, isSelected: index == selectedIndex)
            row.onSelect = { [weak self, suggestion] in
                self?.onSelect?(suggestion)
            }
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        }

        preferredContentSize = NSSize(
            width: contentWidth,
            height: CGFloat(suggestions.count) * (rowHeight + stackView.spacing) - stackView.spacing + 16
        )
        view.setFrameSize(preferredContentSize)
    }
}

@MainActor
private final class AddressSuggestionRowView: NSControl {
    var onSelect: (() -> Void)?

    private let iconContainer = NSView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private var isSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.wantsLayer = true
        iconContainer.layer?.cornerRadius = 10
        iconContainer.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        iconView.contentTintColor = .controlAccentColor

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13.5, weight: .bold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingMiddle
        detailField.maximumNumberOfLines = 1
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconContainer)
        iconContainer.addSubview(iconView)
        addSubview(titleField)
        addSubview(detailField)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 34),
            iconContainer.heightAnchor.constraint(equalToConstant: 34),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),

            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleField.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 11),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(suggestion: AddressSuggestion, isSelected: Bool) {
        self.isSelected = isSelected
        iconView.image = NSImage(systemSymbolName: suggestion.symbolName, accessibilityDescription: suggestion.title)
        titleField.stringValue = suggestion.title
        detailField.stringValue = suggestion.detail
        applyState()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    private func applyState() {
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        iconContainer.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
            : NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    }
}

@MainActor
private final class CurrencyConverterViewController: NSViewController {
    var onConvert: ((CurrencyConversionRequest) -> Void)?
    var onScanPage: (() -> Void)?

    private let amountField = NSTextField()
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let convertButton = NSButton(title: "Посчитать", target: nil, action: nil)
    private let scanButton = NSButton(title: "Найти цену на странице", target: nil, action: nil)
    private let swapButton = NSButton(title: "Поменять валюты", target: nil, action: nil)
    private let resultContainer = NSView()
    private let resultField = NSTextField(labelWithString: "Выделите цену или нажмите сканирование.")
    private let rateField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "Правая кнопка по цене на сайте тоже откроет конвертацию.")

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let root = NSStackView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        view.addSubview(root)

        let titleField = NSTextField(labelWithString: "Конвертер валют")
        titleField.font = .systemFont(ofSize: 18, weight: .bold)

        resultContainer.translatesAutoresizingMaskIntoConstraints = false
        resultContainer.wantsLayer = true
        resultContainer.layer?.cornerRadius = 12
        resultContainer.layer?.borderWidth = 1
        resultContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.34).cgColor
        resultContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42).cgColor

        resultField.translatesAutoresizingMaskIntoConstraints = false
        resultField.font = .systemFont(ofSize: 19, weight: .bold)
        resultField.lineBreakMode = .byWordWrapping
        resultField.maximumNumberOfLines = 3

        rateField.translatesAutoresizingMaskIntoConstraints = false
        rateField.font = .systemFont(ofSize: 12)
        rateField.textColor = .secondaryLabelColor
        rateField.lineBreakMode = .byWordWrapping
        rateField.maximumNumberOfLines = 3

        resultContainer.addSubview(resultField)
        resultContainer.addSubview(rateField)

        amountField.translatesAutoresizingMaskIntoConstraints = false
        amountField.placeholderString = "Сумма"
        amountField.font = .systemFont(ofSize: 16, weight: .semibold)
        amountField.bezelStyle = .roundedBezel
        amountField.target = self
        amountField.action = #selector(convert(_:))

        [sourcePopup, targetPopup].forEach { popup in
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.controlSize = .regular
            popup.font = .systemFont(ofSize: 13)
            popup.removeAllItems()
            popup.addItems(withTitles: CurrencyCode.allCases.map(\.title))
        }

        [convertButton, scanButton, swapButton].forEach { button in
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        convertButton.target = self
        convertButton.action = #selector(convert(_:))
        scanButton.target = self
        scanButton.action = #selector(scanPage(_:))
        swapButton.target = self
        swapButton.action = #selector(swapCurrencies(_:))

        hintField.font = .systemFont(ofSize: 12)
        hintField.textColor = .secondaryLabelColor
        hintField.lineBreakMode = .byWordWrapping
        hintField.maximumNumberOfLines = 2

        let currencyGrid = NSGridView(views: [
            [labeledControl(title: "Сумма", control: amountField)],
            [labeledControl(title: "Из", control: sourcePopup)],
            [labeledControl(title: "В", control: targetPopup)]
        ])
        currencyGrid.translatesAutoresizingMaskIntoConstraints = false
        currencyGrid.rowSpacing = 10

        let buttonRow = NSStackView(views: [convertButton, scanButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8

        root.addArrangedSubview(titleField)
        root.addArrangedSubview(resultContainer)
        root.addArrangedSubview(currencyGrid)
        root.addArrangedSubview(swapButton)
        root.addArrangedSubview(buttonRow)
        root.addArrangedSubview(hintField)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 390),

            resultContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 98),
            resultField.topAnchor.constraint(equalTo: resultContainer.topAnchor, constant: 14),
            resultField.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor, constant: 14),
            resultField.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor, constant: -14),

            rateField.topAnchor.constraint(equalTo: resultField.bottomAnchor, constant: 8),
            rateField.leadingAnchor.constraint(equalTo: resultField.leadingAnchor),
            rateField.trailingAnchor.constraint(equalTo: resultField.trailingAnchor),
            rateField.bottomAnchor.constraint(lessThanOrEqualTo: resultContainer.bottomAnchor, constant: -14)
        ])

        preferredContentSize = NSSize(width: 390, height: 430)
    }

    func configure(amount: Double?, source: CurrencyCode, target: CurrencyCode, apiKeyPresent: Bool, canScanPage: Bool) {
        if let amount {
            amountField.stringValue = CurrencyDisplay.plainAmount(amount)
        } else if amountField.stringValue.isEmpty {
            amountField.stringValue = ""
        }

        select(source, in: sourcePopup)
        select(target, in: targetPopup)
        resultField.stringValue = apiKeyPresent
            ? "Готов к конвертации"
            : "Ключ API не настроен"
        rateField.stringValue = ""
        scanButton.isEnabled = canScanPage
        convertButton.isEnabled = apiKeyPresent
        hintField.stringValue = canScanPage
            ? "Можно выделить цену, открыть меню правой кнопкой или отсканировать страницу."
            : "Откройте обычную страницу, чтобы сканировать цены."
    }

    func showLoading() {
        convertButton.isEnabled = false
        scanButton.isEnabled = false
        resultField.stringValue = "Считаю..."
        rateField.stringValue = ""
    }

    func showScanning() {
        convertButton.isEnabled = false
        scanButton.isEnabled = false
        resultField.stringValue = "Ищу цену на странице..."
        rateField.stringValue = ""
    }

    func showResult(_ result: CurrencyConversionResult) {
        convertButton.isEnabled = true
        scanButton.isEnabled = true
        resultField.stringValue = "\(CurrencyDisplay.amount(result.amount, code: result.source)) = \(CurrencyDisplay.amount(result.convertedAmount, code: result.target))"
        var details = "Курс: 1 \(result.source.rawValue) = \(CurrencyDisplay.rate(result.rate)) \(result.target.rawValue)"
        if let updatedAt = result.updatedAt {
            details += "\nОбновлено: \(updatedAt)"
        }
        rateField.stringValue = details
    }

    func showError(_ message: String) {
        convertButton.isEnabled = true
        scanButton.isEnabled = true
        resultField.stringValue = message
        rateField.stringValue = ""
    }

    @objc private func convert(_ sender: Any?) {
        guard let amount = CurrencyAmountParser.number(from: amountField.stringValue) else {
            showError("Введите сумму в формате 129,99 или 129.99.")
            return
        }

        let source = selectedCurrency(in: sourcePopup)
        let target = selectedCurrency(in: targetPopup)
        onConvert?(CurrencyConversionRequest(amount: amount, source: source, target: target))
    }

    @objc private func scanPage(_ sender: Any?) {
        onScanPage?()
    }

    @objc private func swapCurrencies(_ sender: Any?) {
        let source = selectedCurrency(in: sourcePopup)
        let target = selectedCurrency(in: targetPopup)
        select(target, in: sourcePopup)
        select(source, in: targetPopup)
    }

    private func labeledControl(title: String, control: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .secondaryLabelColor

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(control)
        return stack
    }

    private func select(_ code: CurrencyCode, in popup: NSPopUpButton) {
        if let index = CurrencyCode.allCases.firstIndex(of: code) {
            popup.selectItem(at: index)
        }
    }

    private func selectedCurrency(in popup: NSPopUpButton) -> CurrencyCode {
        let index = popup.indexOfSelectedItem
        guard CurrencyCode.allCases.indices.contains(index) else {
            return .usd
        }

        return CurrencyCode.allCases[index]
    }
}

private enum CurrencyDisplay {
    static func plainAmount(_ amount: Double) -> String {
        plainFormatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    static func amount(_ amount: Double, code: CurrencyCode) -> String {
        "\(plainAmount(amount)) \(code.rawValue)"
    }

    static func rate(_ amount: Double) -> String {
        rateFormatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private static let plainFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let rateFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return formatter
    }()
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class TabRowView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let indicatorView = NSView()
    private let faviconImageView = NSImageView()
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
    private var faviconSizeConstraints: [NSLayoutConstraint] = []
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

        faviconImageView.translatesAutoresizingMaskIntoConstraints = false
        faviconImageView.imageScaling = .scaleProportionallyDown
        faviconImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        faviconImageView.contentTintColor = .tertiaryLabelColor

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
        addSubview(faviconImageView)
        addSubview(titleField)
        addSubview(detailField)
        addSubview(closeButton)

        let height = heightAnchor.constraint(equalToConstant: 58)
        let titleTop = titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        let titleCenterY = titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        let titleLeading = titleField.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 8)
        let indicatorWidth = indicatorView.widthAnchor.constraint(equalToConstant: 3)
        let faviconWidth = faviconImageView.widthAnchor.constraint(equalToConstant: 16)
        let faviconHeight = faviconImageView.heightAnchor.constraint(equalToConstant: 16)
        heightConstraint = height
        titleTopConstraint = titleTop
        titleCenterYConstraint = titleCenterY
        titleLeadingConstraint = titleLeading
        indicatorWidthConstraint = indicatorWidth
        faviconSizeConstraints = [faviconWidth, faviconHeight]

        NSLayoutConstraint.activate([
            height,

            indicatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            indicatorView.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            indicatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            indicatorWidth,

            faviconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            faviconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconWidth,
            faviconHeight,

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

    func configure(title: String, detail: String, favicon: NSImage?, isActive: Bool, isHorizontal: Bool, design: DesignMode) {
        titleField.stringValue = title
        detailField.stringValue = detail
        detailField.isHidden = true
        setFavicon(favicon)
        self.isActive = isActive
        isHorizontalLayout = isHorizontal
        layer?.cornerRadius = design.rowCornerRadius
        heightConstraint?.constant = isHorizontal ? design.horizontalTabRowHeight : design.verticalTabRowHeight
        indicatorView.isHidden = isHorizontal
        indicatorWidthConstraint?.constant = isHorizontal ? 0 : 3
        titleLeadingConstraint?.constant = isHorizontal ? 7 : 8
        faviconSizeConstraints.forEach { $0.constant = isHorizontal ? 16 : 17 }
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

    private func setFavicon(_ image: NSImage?) {
        if let image {
            faviconImageView.image = image
            faviconImageView.contentTintColor = image.isTemplate ? .secondaryLabelColor : nil
            faviconImageView.alphaValue = 1
        } else {
            faviconImageView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Сайт")
            faviconImageView.contentTintColor = .tertiaryLabelColor
            faviconImageView.alphaValue = 0.72
        }
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

private final class ToolbarActionButton: NSButton {
    init(symbolName: String, title: String, tooltip: String, width: CGFloat, height: CGFloat = 30) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        self.title = title
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        imagePosition = .imageLeading
        bezelStyle = .texturedRounded
        isBordered = true
        font = .systemFont(ofSize: 12, weight: .semibold)
        toolTip = tooltip
        setButtonType(.momentaryPushIn)

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
    static func url(from input: String, searchEngine: SearchEngine, region: SearchRegion, language: SearchLanguage) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let directURL = directURL(from: trimmed) {
            return directURL
        }

        return searchEngine.searchURL(for: trimmed, region: region, language: language)
    }

    static func directURL(from input: String) -> URL? {
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

        return nil
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

private enum ParserPage {
    static func html(snapshot: PageParseSnapshot, theme: ThemeMode, colorScheme: ColorSchemeMode, design: DesignMode) -> String {
        let colors = HomePalette(theme: theme, colorScheme: colorScheme, design: design)
        let jsonPayload = json(from: snapshot)
        let markdownPayload = markdown(from: snapshot)
        let textPayload = snapshot.visibleText
        let linkPayload = snapshot.links.map { "\($0.text)\t\($0.href)" }.joined(separator: "\n")
        let htmlPayload = snapshot.html
        let source = snapshot.url.isEmpty ? "Неизвестный источник" : snapshot.url
        let title = snapshot.title.isEmpty ? "Страница без заголовка" : snapshot.title
        let description = snapshot.description.isEmpty ? "Описание не найдено" : snapshot.description
        let htmlNote = snapshot.htmlTruncated ? "HTML обрезан до безопасного лимита" : "HTML полностью в снимке"
        let headingRows = snapshot.headings.isEmpty
            ? #"<p class="empty">Заголовки не найдены.</p>"#
            : snapshot.headings.map { heading in
                """
                <tr>
                  <td>H\(heading.level)</td>
                  <td>\(heading.text.htmlEscaped)</td>
                </tr>
                """
            }.joined()
        let linkRows = snapshot.links.prefix(80).map { link in
            """
            <tr>
              <td>\(link.text.htmlEscaped)</td>
              <td><a href="\(link.href.htmlEscaped)">\(link.href.htmlEscaped)</a></td>
            </tr>
            """
        }.joined()
        let imageRows = snapshot.images.prefix(60).map { image in
            """
            <tr>
              <td>\(image.alt.htmlEscaped)</td>
              <td><a href="\(image.src.htmlEscaped)">\(image.src.htmlEscaped)</a></td>
            </tr>
            """
        }.joined()

        return """
        <!doctype html>
        <html lang="ru">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <base target="_blank">
          <title>\(parserTitle)</title>
          <style>
            :root {
              color-scheme: \(colors.colorScheme);
              --bg: \(colors.background);
              --panel: \(colors.panel);
              --panel-strong: \(colors.panelStrong);
              --text: \(colors.text);
              --muted: \(colors.muted);
              --line: \(colors.line);
              --accent: \(colors.accent);
              --shadow: \(colors.shadow);
              --radius: \(design.radius);
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              min-height: 100vh;
              background: var(--bg);
              color: var(--text);
              font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            }
            main {
              width: min(100vw - 40px, \(design.settingsWidth));
              margin: 0 auto;
              padding: 30px 0 44px;
            }
            header {
              display: grid;
              gap: 8px;
              margin-bottom: 18px;
            }
            h1, h2, p { margin: 0; }
            h1 { font-size: clamp(30px, 4vw, 56px); letter-spacing: 0; }
            h2 { font-size: 18px; }
            a { color: var(--text); }
            .muted, small { color: var(--muted); }
            .source {
              overflow-wrap: anywhere;
              color: var(--muted);
            }
            .toolbar {
              display: flex;
              flex-wrap: wrap;
              gap: 10px;
              margin: 18px 0;
            }
            button {
              min-height: 34px;
              border-radius: var(--radius);
              border: 1px solid var(--line);
              background: var(--panel-strong);
              color: var(--text);
              padding: 0 12px;
              font: inherit;
              font-weight: 750;
            }
            button:hover { border-color: color-mix(in srgb, var(--accent) 58%, var(--line)); }
            .metric-grid {
              display: grid;
              grid-template-columns: repeat(5, minmax(0, 1fr));
              gap: 10px;
              margin-bottom: 16px;
            }
            .metric {
              min-height: 74px;
              display: grid;
              align-content: center;
              gap: 6px;
              border: 1px solid var(--line);
              border-radius: var(--radius);
              background: var(--panel);
              padding: 12px;
              box-shadow: 0 14px 34px var(--shadow);
            }
            .metric span {
              color: var(--muted);
              font-size: 12px;
            }
            .metric strong {
              font-size: 18px;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            section {
              margin-top: 16px;
              border: 1px solid var(--line);
              border-radius: var(--radius);
              background: var(--panel);
              box-shadow: 0 14px 34px var(--shadow);
              overflow: hidden;
            }
            .section-head {
              display: flex;
              align-items: center;
              justify-content: space-between;
              gap: 12px;
              padding: 14px 16px;
              border-bottom: 1px solid var(--line);
              background: var(--panel-strong);
            }
            textarea {
              display: block;
              width: 100%;
              min-height: 220px;
              resize: vertical;
              border: 0;
              border-top: 1px solid var(--line);
              background: color-mix(in srgb, var(--panel) 90%, black 4%);
              color: var(--text);
              padding: 14px;
              font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
              line-height: 1.5;
            }
            table {
              width: 100%;
              border-collapse: collapse;
              table-layout: fixed;
            }
            th, td {
              border-top: 1px solid var(--line);
              padding: 10px 12px;
              text-align: left;
              vertical-align: top;
              overflow-wrap: anywhere;
            }
            th {
              color: var(--muted);
              font-size: 12px;
              font-weight: 750;
              background: var(--panel-strong);
            }
            .empty {
              padding: 14px 16px;
              color: var(--muted);
            }
            @media (max-width: 880px) {
              main { width: min(100vw - 28px, \(design.settingsWidth)); }
              .metric-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
              .section-head { align-items: start; flex-direction: column; }
            }
          </style>
        </head>
        <body>
          <main>
            <header>
              <h1>\(parserTitle)</h1>
              <p class="source">\(source.htmlEscaped)</p>
              <p class="muted">\(title.htmlEscaped) · \(description.htmlEscaped)</p>
            </header>

            <div class="metric-grid">
              <div class="metric"><span>Текст</span><strong>\(snapshot.textCharacters)</strong></div>
              <div class="metric"><span>Ссылки</span><strong>\(snapshot.links.count)</strong></div>
              <div class="metric"><span>Заголовки</span><strong>\(snapshot.headings.count)</strong></div>
              <div class="metric"><span>Изображения</span><strong>\(snapshot.images.count)</strong></div>
              <div class="metric"><span>HTML</span><strong>\(snapshot.htmlCharacters)</strong></div>
            </div>

            <div class="toolbar">
              <button data-copy="json">JSON</button>
              <button data-copy="markdown">Markdown</button>
              <button data-copy="text">Текст</button>
              <button data-copy="links">Ссылки</button>
              <button data-copy="html">HTML</button>
            </div>

            <section>
              <div class="section-head">
                <div>
                  <h2>JSON</h2>
                  <small>\(snapshot.capturedAt.htmlEscaped)</small>
                </div>
              </div>
              <textarea id="json" readonly>\(jsonPayload.htmlEscaped)</textarea>
            </section>

            <section>
              <div class="section-head">
                <div>
                  <h2>Markdown</h2>
                  <small>\(htmlNote.htmlEscaped)</small>
                </div>
              </div>
              <textarea id="markdown" readonly>\(markdownPayload.htmlEscaped)</textarea>
            </section>

            <section>
              <div class="section-head"><h2>Текст</h2></div>
              <textarea id="text" readonly>\(textPayload.htmlEscaped)</textarea>
            </section>

            <section>
              <div class="section-head"><h2>Заголовки</h2></div>
              \(headingRows)
            </section>

            <section>
              <div class="section-head">
                <h2>Ссылки</h2>
                <small>Показаны первые \(min(snapshot.links.count, 80))</small>
              </div>
              <textarea id="links" readonly>\(linkPayload.htmlEscaped)</textarea>
              \(linkRows.isEmpty ? #"<p class="empty">Ссылки не найдены.</p>"# : """
              <table>
                <thead><tr><th>Текст</th><th>URL</th></tr></thead>
                <tbody>\(linkRows)</tbody>
              </table>
              """)
            </section>

            <section>
              <div class="section-head">
                <h2>Изображения</h2>
                <small>Показаны первые \(min(snapshot.images.count, 60))</small>
              </div>
              \(imageRows.isEmpty ? #"<p class="empty">Изображения не найдены.</p>"# : """
              <table>
                <thead><tr><th>Alt</th><th>URL</th></tr></thead>
                <tbody>\(imageRows)</tbody>
              </table>
              """)
            </section>

            <section>
              <div class="section-head">
                <div>
                  <h2>HTML</h2>
                  <small>\(htmlNote.htmlEscaped)</small>
                </div>
              </div>
              <textarea id="html" readonly>\(htmlPayload.htmlEscaped)</textarea>
            </section>
          </main>
          <script>
            document.querySelectorAll('[data-copy]').forEach((button) => {
              button.addEventListener('click', async () => {
                const id = button.getAttribute('data-copy');
                const field = document.getElementById(id);
                if (!field) return;
                await navigator.clipboard.writeText(field.value);
                const previous = button.textContent;
                button.textContent = 'Скопировано';
                window.setTimeout(() => { button.textContent = previous; }, 900);
              });
            });
          </script>
        </body>
        </html>
        """
    }

    private static func json(from snapshot: PageParseSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    private static func markdown(from snapshot: PageParseSnapshot) -> String {
        let title = snapshot.title.isEmpty ? "Страница" : snapshot.title
        let description = snapshot.description.isEmpty ? "" : "\n\n\(snapshot.description)"
        let headings = snapshot.headings.prefix(80).map { heading in
            "\(String(repeating: "#", count: max(1, min(heading.level, 6)))) \(heading.text)"
        }.joined(separator: "\n")
        let links = snapshot.links.prefix(120).map { link in
            "- [\(link.text.isEmpty ? link.href : link.text)](\(link.href))"
        }.joined(separator: "\n")

        return """
        # \(title)

        \(snapshot.url)\(description)

        ## Заголовки
        \(headings.isEmpty ? "Нет данных" : headings)

        ## Текст
        \(snapshot.visibleText)

        ## Ссылки
        \(links.isEmpty ? "Нет данных" : links)
        """
    }
}

private enum HomePage {
    static func html(searchEngine: SearchEngine, searchRegion: SearchRegion, searchLanguage: SearchLanguage, theme: ThemeMode, colorScheme: ColorSchemeMode, design: DesignMode, homeBackground: HomeBackgroundMode, recentHistory: [BrowserHistoryEntry]) -> String {
        let palette = HomePalette(theme: theme, colorScheme: colorScheme, design: design)
        let engine = searchEngine.title.htmlEscaped
        let region = searchRegion.title.htmlEscaped
        let language = searchLanguage.title.htmlEscaped
        let engineOptions = SearchEngine.allCases.map { option in
            let selected = option == searchEngine ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let regionOptions = SearchRegion.allCases.map { option in
            let selected = option == searchRegion ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let languageOptions = SearchLanguage.allCases.map { option in
            let selected = option == searchLanguage ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let recentMarkup = recentHistory.prefix(6).map { entry in
            """
            <a class="recent-item" href="\(entry.url.htmlEscaped)">
              <span class="site-dot"></span>
              <span class="recent-copy">
                <strong>\(entry.title.htmlEscaped)</strong>
                <small>\(entry.url.htmlEscaped)</small>
              </span>
            </a>
            """
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
              overflow: auto;
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
            body::after {
              content: "";
              position: fixed;
              inset: 0;
              pointer-events: none;
              background:
                linear-gradient(90deg, color-mix(in srgb, var(--accent) 10%, transparent), transparent 38%),
                linear-gradient(180deg, rgba(255,255,255,0.04), transparent 42%);
            }
            main {
              width: min(var(--page-width), calc(100vw - 48px));
              display: grid;
              gap: 18px;
              position: relative;
              z-index: 1;
              margin: 34px auto 48px;
            }
            .hero {
              display: grid;
              grid-template-columns: auto minmax(0, 1fr);
              gap: 18px;
              align-items: center;
              padding: 18px 2px 4px;
            }
            .brand-chip {
              width: 58px;
              height: 58px;
              display: grid;
              place-items: center;
              border: 1px solid color-mix(in srgb, var(--accent) 38%, var(--line));
              border-radius: 16px;
              background: color-mix(in srgb, var(--panel) 72%, transparent);
              box-shadow: 0 18px 44px var(--shadow);
              font-weight: 900;
              font-size: 18px;
            }
            h1 {
              margin: 0;
              font-size: clamp(44px, 7vw, 76px);
              line-height: 0.92;
              letter-spacing: 0;
              font-weight: 800;
            }
            .kicker {
              margin: 0 0 6px;
              color: var(--accent);
              font-size: 12px;
              font-weight: 800;
              letter-spacing: 0.08em;
              text-transform: uppercase;
            }
            .sub {
              margin: 10px 0 0;
              color: var(--muted);
              font-size: 16px;
              line-height: 1.45;
            }
            .command {
              display: grid;
              gap: 12px;
              padding: 14px;
              border: 1px solid var(--line);
              border-radius: 18px;
              background: color-mix(in srgb, var(--panel) 88%, transparent);
              box-shadow: 0 24px 64px var(--shadow);
              backdrop-filter: blur(18px);
            }
            .search {
              display: grid;
              grid-template-columns: minmax(240px, 1fr) auto;
              gap: 10px;
            }
            input {
              width: 100%;
              min-width: 0;
              min-height: 58px;
              border: 1px solid transparent;
              outline: 0;
              border-radius: 14px;
              padding: 0 18px;
              font-size: 17px;
              font-weight: 650;
              color: var(--text);
              background: color-mix(in srgb, var(--panel-strong) 58%, transparent);
            }
            input:focus { border-color: color-mix(in srgb, var(--accent) 54%, var(--line)); }
            input::placeholder { color: var(--muted); }
            select {
              appearance: none;
              -webkit-appearance: none;
              width: 100%;
              min-width: 0;
              min-height: 30px;
              border: 0;
              outline: 0;
              border-radius: 10px;
              padding: 0 28px 0 0;
              font-size: 14px;
              font-weight: 800;
              color: var(--text);
              background: transparent;
              cursor: pointer;
            }
            button {
              border: 0;
              border-radius: 14px;
              padding: 0 22px;
              min-width: 118px;
              min-height: 58px;
              font-size: 15px;
              font-weight: 850;
              color: #071015;
              background: linear-gradient(135deg, var(--accent), var(--accent-2));
              cursor: pointer;
            }
            button:hover { filter: brightness(1.05); }
            .filters {
              display: grid;
              grid-template-columns: repeat(3, minmax(0, 1fr));
              gap: 10px;
            }
            .filter {
              display: grid;
              gap: 5px;
              padding: 10px 12px;
              border: 1px solid color-mix(in srgb, var(--line) 78%, transparent);
              border-radius: 14px;
              background: color-mix(in srgb, var(--panel-strong) 48%, transparent);
              position: relative;
            }
            .filter::after {
              content: "";
              position: absolute;
              right: 14px;
              bottom: 20px;
              width: 7px;
              height: 7px;
              border-right: 2px solid var(--muted);
              border-bottom: 2px solid var(--muted);
              transform: rotate(45deg);
              pointer-events: none;
            }
            .filter span,
            .section-label,
            .context {
              color: var(--muted);
              font-size: 11px;
              font-weight: 800;
              letter-spacing: 0.04em;
              text-transform: uppercase;
            }
            .context {
              display: flex;
              gap: 8px;
              align-items: center;
              text-transform: none;
              letter-spacing: 0;
              font-size: 13px;
              font-weight: 650;
            }
            .context::before {
              content: "";
              width: 7px;
              height: 7px;
              border-radius: 999px;
              background: var(--accent);
            }
            .dashboard {
              display: grid;
              grid-template-columns: minmax(0, 1.05fr) minmax(260px, 0.95fr);
              gap: 14px;
              align-items: start;
            }
            .stack {
              display: grid;
              gap: 14px;
            }
            .panel {
              display: grid;
              gap: 12px;
              padding: 16px;
              border: 1px solid var(--line);
              border-radius: 18px;
              background: color-mix(in srgb, var(--panel) 82%, transparent);
              box-shadow: 0 16px 42px var(--shadow);
              backdrop-filter: blur(16px);
            }
            .panel-head {
              display: flex;
              justify-content: space-between;
              align-items: center;
              gap: 12px;
            }
            .panel h2 {
              margin: 0;
              font-size: 16px;
              line-height: 1.2;
            }
            .quick {
              display: grid;
              grid-template-columns: repeat(2, minmax(0, 1fr));
              gap: 10px;
            }
            .quick-link,
            .action-link,
            .recent-item {
              color: var(--text);
              text-decoration: none;
              border: 1px solid var(--line);
              border-radius: 14px;
              background: color-mix(in srgb, var(--panel-strong) 46%, transparent);
              font-size: 14px;
              font-weight: 760;
            }
            .quick-link {
              min-height: 74px;
              display: grid;
              align-content: center;
              gap: 7px;
              padding: 13px;
            }
            .quick-link small {
              min-width: 0;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
              color: var(--muted);
              font-size: 12px;
            }
            .quick-link:hover,
            .action-link:hover,
            .recent-item:hover {
              border-color: color-mix(in srgb, var(--accent) 56%, var(--line));
              background: color-mix(in srgb, var(--accent) 10%, var(--panel));
            }
            .actions {
              display: grid;
              gap: 9px;
            }
            .action-link {
              min-height: 54px;
              display: flex;
              justify-content: space-between;
              align-items: center;
              padding: 0 14px;
            }
            .arrow {
              color: var(--accent);
              font-weight: 900;
            }
            .recent {
              display: grid;
              gap: 9px;
              max-height: 350px;
              overflow: auto;
              padding-right: 2px;
            }
            .recent-item {
              display: grid;
              grid-template-columns: auto minmax(0, 1fr);
              gap: 10px;
              align-items: center;
              min-height: 58px;
              padding: 10px 12px;
            }
            .site-dot {
              width: 28px;
              height: 28px;
              border-radius: 10px;
              background: linear-gradient(135deg, var(--accent), var(--accent-2));
              box-shadow: inset 0 0 0 1px rgba(255,255,255,0.34);
            }
            .recent-copy {
              min-width: 0;
              display: grid;
              gap: 3px;
            }
            .recent-copy strong,
            .recent-copy small {
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .recent-copy small {
              color: var(--muted);
              font-size: 12px;
            }
            .empty {
              margin: 0;
              color: var(--muted);
              border: 1px dashed var(--line);
              border-radius: 14px;
              padding: 15px;
              font-size: 13px;
            }
            @media (max-width: 960px) {
              .dashboard { grid-template-columns: 1fr; }
              .filters { grid-template-columns: 1fr; }
            }
            @media (max-width: 680px) {
              main { width: min(var(--page-width), calc(100vw - 28px)); margin-top: 22px; }
              .hero { grid-template-columns: 1fr; }
              .search { grid-template-columns: 1fr; }
              input, button { min-height: 50px; }
              .quick { grid-template-columns: repeat(2, minmax(0, 1fr)); }
            }
          </style>
        </head>
        <body>
          <main>
            <section class="hero" aria-label="NorthStar">
              <div class="brand-chip">NS</div>
              <div>
                <p class="kicker">Браузер NorthStar</p>
                <h1>Быстрый старт</h1>
                <p class="sub">Поиск, сайты, настройки и последние страницы в одном спокойном рабочем экране.</p>
              </div>
            </section>
            <section class="command" aria-label="Поиск">
              <form class="search" id="searchForm">
                <input id="query" name="q" autofocus autocomplete="off" placeholder="Поиск или адрес сайта">
                <button type="submit">Открыть</button>
              </form>
              <div class="filters" aria-label="Настройки поиска">
                <label class="filter">
                  <span>Регион</span>
                  <select id="region" name="region" aria-label="Регион поиска">
                    \(regionOptions)
                  </select>
                </label>
                <label class="filter">
                  <span>Язык</span>
                  <select id="language" name="language" aria-label="Язык поиска">
                    \(languageOptions)
                  </select>
                </label>
                <label class="filter">
                  <span>Движок</span>
                  <select id="engine" name="engine" aria-label="Поисковая система">
                    \(engineOptions)
                  </select>
                </label>
              </div>
              <div class="context">\(engine) · \(region) · \(language)</div>
            </section>
            <section class="dashboard" aria-label="Быстрый старт">
              <div class="stack">
                <div class="panel">
                  <div class="panel-head">
                    <h2>Быстрые ссылки</h2>
                    <span class="section-label">Закреплено</span>
                  </div>
                  <nav class="quick" aria-label="Быстрые ссылки">
                    <a class="quick-link" href="https://github.com"><strong>GitHub</strong><small>github.com</small></a>
                    <a class="quick-link" href="https://news.ycombinator.com"><strong>Hacker News</strong><small>news.ycombinator.com</small></a>
                    <a class="quick-link" href="https://developer.apple.com"><strong>Apple Dev</strong><small>developer.apple.com</small></a>
                    <a class="quick-link" href="http://localhost:3000"><strong>Localhost</strong><small>localhost:3000</small></a>
                  </nav>
                </div>
                <div class="panel">
                  <div class="panel-head">
                    <h2>Действия</h2>
                    <span class="section-label">Инструменты</span>
                  </div>
                  <div class="actions">
                    <a class="action-link" href="\(northStarSettingsScheme)://home">Настройки <span class="arrow">→</span></a>
                    <a class="action-link" href="https://mediamarkt.pl">MediaMarkt PL <span class="arrow">→</span></a>
                  </div>
                </div>
              </div>
              <div class="panel">
                <div class="panel-head">
                  <h2>Недавние страницы</h2>
                  <span class="section-label">История</span>
                </div>
                <div class="recent">
                  \(recentMarkup.isEmpty ? "<p class=\"empty\">История пока пуста.</p>" : recentMarkup)
                </div>
              </div>
            </section>
          </main>
          <script>
            const form = document.getElementById("searchForm");
            const query = document.getElementById("query");
            const engine = document.getElementById("engine");
            const region = document.getElementById("region");
            const language = document.getElementById("language");
            const updateContext = () => {
              const params = new URLSearchParams({
                engine: engine.value,
                region: region.value,
                language: language.value
              });
              window.location.href = "\(northStarSearchScheme)://engine?" + params.toString();
            };
            [engine, region, language].forEach(control => {
              control.addEventListener("change", updateContext);
            });
            form.addEventListener("submit", event => {
              event.preventDefault();
              const value = query.value.trim();
              if (!value) return;
              const params = new URLSearchParams({
                q: value,
                engine: engine.value,
                region: region.value,
                language: language.value
              });
              window.location.href = "\(northStarSearchScheme)://search?" + params.toString();
            });
          </script>
        </body>
        </html>
        """
    }
}

private enum SettingsSection: String, CaseIterable {
    case overview
    case search
    case appearance
    case browser
    case currency
    case performance
    case history
    case downloads

    var identifier: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "Обзор"
        case .search:
            return "Поиск"
        case .appearance:
            return "Внешний вид"
        case .browser:
            return "Браузер"
        case .currency:
            return "Валюты"
        case .performance:
            return "Производительность"
        case .history:
            return "История"
        case .downloads:
            return "Загрузки"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            return "Короткая сводка"
        case .search:
            return "Движок, регион и язык"
        case .appearance:
            return "Тема, цвета и главный экран"
        case .browser:
            return "Вкладки и блокировка рекламы"
        case .currency:
            return "Курс и конвертация"
        case .performance:
            return "Состояние текущего окна"
        case .history:
            return "Посещённые страницы"
        case .downloads:
            return "Сохранённые файлы"
        }
    }

    init?(identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let section = Self.allCases.first(where: { $0.identifier == normalized }) else {
            return nil
        }

        self = section
    }
}

private enum SettingsPage {
    static func html(preferences: AppPreferences, history: [BrowserHistoryEntry], downloads: [DownloadHistoryEntry], performance: PerformanceSnapshot, theme: ThemeMode, activeSection: SettingsSection, defaultAppStatus: String?) -> String {
        let palette = HomePalette(theme: theme, colorScheme: preferences.colorScheme, design: preferences.design)
        let activeSectionID = activeSection.identifier.htmlEscaped
        let defaultAppStatusMarkup = defaultAppStatus.map { message in
            """
            <div class="notice">\(message.htmlEscaped)</div>
            """
        } ?? ""
        let navMarkup = SettingsSection.allCases.map { section in
            let active = section == activeSection ? " active" : ""
            return """
            <button class="nav-item\(active)" type="button" data-section="\(section.identifier.htmlEscaped)">
              <strong>\(section.title.htmlEscaped)</strong>
              <span>\(section.subtitle.htmlEscaped)</span>
            </button>
            """
        }.joined()
        let searchOptions = SearchEngine.allCases.map { option in
            let selected = option == preferences.searchEngine ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let regionOptions = SearchRegion.allCases.map { option in
            let selected = option == preferences.searchRegion ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let languageOptions = SearchLanguage.allCases.map { option in
            let selected = option == preferences.searchLanguage ? " selected" : ""
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
        let adBlockOptions = AdBlockMode.allCases.map { option in
            let selected = option == preferences.adBlockMode ? " selected" : ""
            return "<option value=\"\(option.identifier)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let currencySourceOptions = CurrencyCode.allCases.map { option in
            let selected = option == preferences.defaultCurrencySource ? " selected" : ""
            return "<option value=\"\(option.rawValue)\"\(selected)>\(option.title.htmlEscaped)</option>"
        }.joined()
        let currencyTargetOptions = CurrencyCode.allCases.map { option in
            let selected = option == preferences.defaultCurrencyTarget ? " selected" : ""
            return "<option value=\"\(option.rawValue)\"\(selected)>\(option.title.htmlEscaped)</option>"
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
              background:
                linear-gradient(135deg, color-mix(in srgb, var(--accent) 8%, transparent), transparent 32%),
                var(--bg);
            }
            .settings-shell {
              min-height: 100vh;
              display: grid;
              grid-template-columns: 244px minmax(0, 1fr);
            }
            .sidebar {
              position: sticky;
              top: 0;
              height: 100vh;
              display: grid;
              align-content: start;
              gap: 18px;
              border-right: 1px solid var(--line);
              background: color-mix(in srgb, var(--panel-strong) 76%, var(--bg));
              padding: 18px 12px;
            }
            .brand {
              display: grid;
              gap: 4px;
              padding: 8px 10px 10px;
              border-bottom: 1px solid var(--line);
            }
            .brand strong {
              font-size: 20px;
              line-height: 1;
            }
            .brand span,
            .nav-item span,
            .muted {
              color: var(--muted);
              font-size: 13px;
            }
            .nav {
              display: grid;
              gap: 5px;
            }
            .nav-item,
            .overview-card {
              appearance: none;
              width: 100%;
              border: 1px solid transparent;
              border-radius: var(--radius);
              background: transparent;
              color: var(--text);
              text-align: left;
              cursor: pointer;
            }
            .nav-item {
              display: grid;
              gap: 4px;
              min-height: 52px;
              padding: 9px 11px;
            }
            .nav-item strong {
              font-size: 14px;
              line-height: 1.15;
            }
            .nav-item.active,
            .nav-item:hover {
              border-color: color-mix(in srgb, var(--accent) 44%, var(--line));
              background: color-mix(in srgb, var(--accent) 13%, var(--panel));
            }
            .content {
              min-width: 0;
              max-height: 100vh;
              overflow: auto;
              padding: 28px;
            }
            .panel {
              width: min(var(--settings-width), 100%);
              display: none;
              gap: 14px;
              margin: 0 auto;
            }
            .panel.active {
              display: grid;
            }
            .panel-head {
              display: grid;
              grid-template-columns: minmax(0, 1fr) auto;
              justify-content: space-between;
              gap: 16px;
              align-items: center;
              border: 1px solid var(--line);
              border-radius: calc(var(--radius) + 2px);
              background: color-mix(in srgb, var(--panel) 86%, transparent);
              box-shadow: 0 14px 34px var(--shadow);
              padding: 18px;
            }
            h1, h2, h3, p { margin: 0; letter-spacing: 0; }
            h1 { font-size: 28px; line-height: 1.05; }
            h2 { font-size: 21px; line-height: 1.15; }
            h3 { font-size: 15px; line-height: 1.2; }
            .overview-grid,
            .control-grid {
              display: grid;
              grid-template-columns: repeat(2, minmax(0, 1fr));
              gap: 12px;
            }
            .overview-card,
            .setting-card,
            .metric,
            .list-row {
              border: 1px solid var(--line);
              border-radius: var(--radius);
              background: color-mix(in srgb, var(--panel) 88%, transparent);
              box-shadow: 0 10px 24px color-mix(in srgb, var(--shadow) 76%, transparent);
            }
            .overview-card {
              min-height: 96px;
              display: grid;
              align-content: center;
              gap: 7px;
              padding: 16px;
            }
            .overview-card:hover {
              border-color: color-mix(in srgb, var(--accent) 55%, var(--line));
            }
            .overview-card span {
              color: var(--muted);
              font-size: 13px;
            }
            .setting-card {
              min-height: 96px;
              display: grid;
              align-content: center;
              gap: 10px;
              padding: 16px;
            }
            label {
              display: grid;
              gap: 8px;
            }
            label span {
              color: var(--muted);
              font-size: 12px;
              font-weight: 700;
              text-transform: uppercase;
            }
            select,
            input {
              appearance: none;
              -webkit-appearance: none;
              width: 100%;
              min-width: 0;
              min-height: 42px;
              border-radius: calc(var(--radius) - 2px);
              border: 1px solid var(--line);
              color: var(--text);
              background:
                linear-gradient(45deg, transparent 50%, var(--muted) 50%) right 16px center / 7px 7px no-repeat,
                linear-gradient(135deg, var(--panel), color-mix(in srgb, var(--panel-strong) 58%, var(--panel)));
              padding: 0 36px 0 12px;
              font-size: 14px;
              font-weight: 760;
            }
            select:focus,
            input:focus {
              outline: 0;
              border-color: color-mix(in srgb, var(--accent) 62%, var(--line));
            }
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
              padding: 14px;
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
              padding: 12px 14px;
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
              min-height: 38px;
              border-radius: calc(var(--radius) - 2px);
              padding: 0 14px;
              border: 1px solid color-mix(in srgb, var(--accent) 42%, var(--line));
              color: #071015;
              background: linear-gradient(135deg, var(--accent), var(--accent-2));
              text-decoration: none;
              font-size: 13px;
              font-weight: 820;
            }
            .notice {
              border: 1px solid color-mix(in srgb, var(--accent) 48%, var(--line));
              border-radius: var(--radius);
              background: color-mix(in srgb, var(--accent) 13%, var(--panel));
              color: var(--text);
              padding: 13px 15px;
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
            .row-meta {
              display: grid;
              gap: 5px;
              justify-items: end;
            }
            .duration {
              font-size: 13px;
            }
            @media (max-width: 860px) {
              .settings-shell { grid-template-columns: 1fr; }
              .sidebar {
                position: static;
                height: auto;
                border-right: 0;
                border-bottom: 1px solid var(--line);
                padding: 16px;
              }
              .nav {
                grid-template-columns: repeat(2, minmax(0, 1fr));
              }
              .content {
                max-height: none;
                overflow: visible;
                padding: 22px 16px 34px;
              }
              .panel-head, .list-row { grid-template-columns: 1fr; }
              .panel-head { align-items: start; }
              .overview-grid, .control-grid { grid-template-columns: 1fr; }
              .metric-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
              time, .status, .row-meta { justify-self: start; justify-items: start; }
            }
          </style>
        </head>
        <body>
          <main class="settings-shell">
            <aside class="sidebar" aria-label="Разделы настроек">
              <div class="brand">
                <strong>\(settingsTitle)</strong>
                <span>\(appName)</span>
              </div>
              <nav class="nav">
                \(navMarkup)
              </nav>
            </aside>

            <div class="content">
              <section class="panel" data-panel="overview" aria-label="Обзор настроек">
                <div class="panel-head">
                  <div>
                    <h1>Обзор</h1>
                    <p class="muted">\(preferences.searchEngine.title.htmlEscaped) · \(preferences.searchRegion.title.htmlEscaped) · \(preferences.searchLanguage.title.htmlEscaped)</p>
                  </div>
                </div>
                <div class="overview-grid">
                  <button class="overview-card" type="button" data-section="search">
                    <h3>Поиск</h3>
                    <span>\(preferences.searchEngine.title.htmlEscaped), \(preferences.searchRegion.title.htmlEscaped), \(preferences.searchLanguage.title.htmlEscaped)</span>
                  </button>
                  <button class="overview-card" type="button" data-section="appearance">
                    <h3>Внешний вид</h3>
                    <span>\(preferences.theme.title.htmlEscaped), \(preferences.colorScheme.title.htmlEscaped), \(preferences.design.title.htmlEscaped)</span>
                  </button>
                  <button class="overview-card" type="button" data-section="currency">
                    <h3>Валюты</h3>
                    <span>\(preferences.defaultCurrencySource.rawValue) → \(preferences.defaultCurrencyTarget.rawValue), ключ скрыт</span>
                  </button>
                  <button class="overview-card" type="button" data-section="history">
                    <h3>История</h3>
                    <span>\(history.count) записей</span>
                  </button>
                  <button class="overview-card" type="button" data-section="downloads">
                    <h3>Загрузки</h3>
                    <span>\(downloads.count) записей</span>
                  </button>
                </div>
              </section>

              <section class="panel" data-panel="search" aria-label="Поиск">
                <div class="panel-head">
                  <div>
                    <h1>Поиск</h1>
                    <p class="muted">Поисковая система, регион выдачи и язык результатов.</p>
                  </div>
                </div>
                <div class="control-grid">
                  <div class="setting-card">
                    <label>
                      <span>Поисковая система</span>
                      <select id="search" data-setting>\(searchOptions)</select>
                    </label>
                  </div>
                  <div class="setting-card">
                    <label>
                      <span>Регион поиска</span>
                      <select id="region" data-setting>\(regionOptions)</select>
                    </label>
                  </div>
                  <div class="setting-card">
                    <label>
                      <span>Язык поиска</span>
                      <select id="language" data-setting>\(languageOptions)</select>
                    </label>
                  </div>
                </div>
              </section>

              <section class="panel" data-panel="appearance" aria-label="Внешний вид">
                <div class="panel-head">
                  <div>
                    <h1>Внешний вид</h1>
                    <p class="muted">Тема, цветовая схема, плотность интерфейса и фон главного экрана.</p>
                  </div>
                </div>
                <div class="control-grid">
                  <div class="setting-card">
                    <label>
                      <span>Тема</span>
                      <select id="theme" data-setting>\(themeOptions)</select>
                    </label>
                  </div>
                  <div class="setting-card">
                    <label>
                      <span>Цветовая схема</span>
                      <select id="scheme" data-setting>\(schemeOptions)</select>
                    </label>
                  </div>
                  <div class="setting-card">
                    <label>
                      <span>Дизайн</span>
                      <select id="design" data-setting>\(designOptions)</select>
                    </label>
                  </div>
                  <div class="setting-card">
                    <label>
                      <span>Главный экран</span>
                      <select id="home" data-setting>\(homeOptions)</select>
                    </label>
                  </div>
                </div>
              </section>

              <section class="panel" data-panel="browser" aria-label="Браузер">
                <div class="panel-head">
                  <div>
                    <h1>Браузер</h1>
                    <p class="muted">Расположение вкладок, блокировка рекламы и системные назначения по умолчанию.</p>
                  </div>
                </div>
                \(defaultAppStatusMarkup)
                <div class="control-grid">
                  <div class="setting-card">
                    <label>
                      <span>Вкладки</span>
                      <select id="tabs" data-setting>\(tabOptions)</select>
                    </label>
                  </div>
                  <div class="setting-card">
                    <label>
                      <span>Блокировка рекламы</span>
                      <select id="adblock" data-setting>\(adBlockOptions)</select>
                    </label>
                  </div>
                  <div class="setting-card">
                    <h3>Браузер по умолчанию</h3>
                    <p class="muted">Назначает NorthStar для ссылок http и https.</p>
                    <a class="button" href="\(northStarSettingsScheme)://default-browser">Сделать по умолчанию</a>
                  </div>
                  <div class="setting-card">
                    <h3>PDF по умолчанию</h3>
                    <p class="muted">Открывает PDF-файлы в NorthStar через WebKit.</p>
                    <a class="button" href="\(northStarSettingsScheme)://default-pdf">Открывать PDF в NorthStar</a>
                  </div>
                </div>
              </section>

              <section class="panel" data-panel="currency" aria-label="Валюты">
                <div class="panel-head">
                  <div>
                    <h1>Валюты</h1>
                    <p class="muted">Конвертер в панели, сканирование цен на странице и пункт контекстного меню.</p>
                  </div>
                </div>
                <div class="control-grid">
                  <div class="setting-card">
                    <label>
                      <span>Валюта цены по умолчанию</span>
                      <select id="currencySource" data-setting>\(currencySourceOptions)</select>
                    </label>
                  </div>
                  <div class="setting-card">
                    <label>
                      <span>Конвертировать в</span>
                      <select id="currencyTarget" data-setting>\(currencyTargetOptions)</select>
                    </label>
                  </div>
                  <div class="setting-card">
                    <h3>Источник курсов</h3>
                    <p class="muted">ExchangeRate-API настроен локально и не показывается в интерфейсе.</p>
                  </div>
                </div>
              </section>

              <section class="panel" data-panel="performance" aria-label="Производительность">
                <div class="panel-head">
                  <div>
                    <h1>Производительность</h1>
                    <p class="muted">Состояние текущего окна и последние загрузки страниц.</p>
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

              <section class="panel" data-panel="history" aria-label="История посещений">
                <div class="panel-head">
                  <div>
                    <h1>История</h1>
                    <p class="muted">Последние открытые страницы.</p>
                  </div>
                  <a class="button" href="\(northStarSettingsScheme)://clear-history">Очистить</a>
                </div>
                <div class="list">
                  \(historyMarkup.isEmpty ? "<p class=\"empty\">История пока пуста.</p>" : historyMarkup)
                </div>
              </section>

              <section class="panel" data-panel="downloads" aria-label="История загрузок">
                <div class="panel-head">
                  <div>
                    <h1>Загрузки</h1>
                    <p class="muted">Файлы сохраняются в папку Загрузки.</p>
                  </div>
                  <a class="button" href="\(northStarSettingsScheme)://clear-downloads">Очистить</a>
                </div>
                <div class="list">
                  \(downloadsMarkup.isEmpty ? "<p class=\"empty\">Загрузок пока нет.</p>" : downloadsMarkup)
                </div>
              </section>
            </div>
          </main>
          <script>
            const fallbackSection = "\(activeSectionID)";
            const panels = Array.from(document.querySelectorAll("[data-panel]"));
            const sectionButtons = Array.from(document.querySelectorAll("[data-section]"));
            const setSection = (section) => {
              const target = panels.some(panel => panel.dataset.panel === section) ? section : fallbackSection;
              panels.forEach(panel => panel.classList.toggle("active", panel.dataset.panel === target));
              sectionButtons.forEach(button => button.classList.toggle("active", button.dataset.section === target));
              if (window.location.hash !== "#" + target) {
                history.replaceState(null, "", "#" + target);
              }
            };
            sectionButtons.forEach(button => {
              button.addEventListener("click", () => setSection(button.dataset.section));
            });
            setSection(window.location.hash.replace("#", "") || fallbackSection);

            const currentSection = () => {
              const active = document.querySelector("[data-panel].active");
              return active ? active.dataset.panel : fallbackSection;
            };
            const update = () => {
              const params = new URLSearchParams({
                section: currentSection(),
                search: document.getElementById("search").value,
                region: document.getElementById("region").value,
                language: document.getElementById("language").value,
                tabs: document.getElementById("tabs").value,
                theme: document.getElementById("theme").value,
                scheme: document.getElementById("scheme").value,
                design: document.getElementById("design").value,
                home: document.getElementById("home").value,
                adblock: document.getElementById("adblock").value,
                currencySource: document.getElementById("currencySource").value,
                currencyTarget: document.getElementById("currencyTarget").value
              });
              window.location.href = "\(northStarSettingsScheme)://update?" + params.toString();
            };
            document.querySelectorAll("[data-setting]").forEach(select => {
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
    func truncatedForSuggestion(maxLength: Int) -> String {
        guard count > maxLength, maxLength > 1 else { return self }
        let end = index(startIndex, offsetBy: maxLength - 1)
        return String(self[..<end]) + "…"
    }

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
    let privateTab = fileMenu.addItem(withTitle: "Новая приватная вкладка", action: #selector(BrowserViewController.newPrivateTabCommand(_:)), keyEquivalent: "n")
    privateTab.keyEquivalentModifierMask = [.command, .shift]
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
    let hardReloadItem = viewMenu.addItem(withTitle: "Жёсткое обновление без кэша", action: #selector(BrowserViewController.hardReloadCommand(_:)), keyEquivalent: "r")
    hardReloadItem.keyEquivalentModifierMask = [.command, .shift]
    viewMenu.addItem(.separator())
    viewMenu.addItem(withTitle: "Предыдущая вкладка", action: #selector(BrowserViewController.previousTabCommand(_:)), keyEquivalent: "{")
    viewMenu.addItem(withTitle: "Следующая вкладка", action: #selector(BrowserViewController.nextTabCommand(_:)), keyEquivalent: "}")
    viewMenu.addItem(.separator())
    let parserItem = viewMenu.addItem(withTitle: "Парсер страницы", action: #selector(BrowserViewController.openParserCommand(_:)), keyEquivalent: "p")
    parserItem.keyEquivalentModifierMask = [.command, .option]
    let screenshotItem = viewMenu.addItem(withTitle: "Скопировать скриншот вкладки", action: #selector(BrowserViewController.screenshotTabCommand(_:)), keyEquivalent: "s")
    screenshotItem.keyEquivalentModifierMask = [.command, .option]
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
