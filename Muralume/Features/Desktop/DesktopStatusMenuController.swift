import AppKit
import Combine

private enum DesktopStatusMenuLayout {
    static let iconSize = NSSize(width: 18, height: 18)
    static let currentPlaybackMaximumWidth: CGFloat = 360
    static let truncationMarker = "…"
}

private enum DesktopStatusMenuAsset {
    static let menuBarMark = NSImage.Name("MenuBarMark")
}

private enum DesktopPlaybackModeMenu {
    static let displayOrder: [PlaybackMode] = [
        .ordered,
        .shuffled,
        .repeatCurrent
    ]
}

private extension PlaybackMode {
    var desktopStatusLocalizedKey: String {
        switch self {
        case .ordered:
            "queue.mode.ordered"
        case .shuffled:
            "queue.mode.shuffled"
        case .repeatCurrent:
            "queue.mode.repeatCurrent"
        }
    }
}

@MainActor
final class DesktopStatusMenuController: NSObject, NSMenuDelegate, DesktopStatusPresenting {
    var stateProvider: (() -> DesktopStatusState)?
    var togglePlaybackHandler: (() -> Void)?
    var playNextHandler: (() -> Void)?
    var setPlaybackOrderHandler: ((PlaybackOrder) -> Void)?
    var setPlaybackModeHandler: ((PlaybackMode) -> Void)?
    var setPlaybackRateHandler: ((PlaybackRate) -> Void)?
    var returnToPlayerHandler: (() -> Void)?
    var setVideoContentModeHandler: ((DesktopVideoContentMode) -> Void)?
    var quitHandler: (() -> Void)?

    private var statusItem: NSStatusItem?
    private weak var currentItem: NSMenuItem?
    private weak var togglePlaybackItem: NSMenuItem?
    private weak var playNextItem: NSMenuItem?
    private weak var playbackModeItem: NSMenuItem?
    private weak var playbackRateItem: NSMenuItem?
    private weak var videoContentModeItem: NSMenuItem?
    private weak var returnItem: NSMenuItem?
    private weak var quitItem: NSMenuItem?
    private var playbackModeItems: [PlaybackMode: NSMenuItem] = [:]
    private var playbackRateItems: [PlaybackRate: NSMenuItem] = [:]
    private var videoContentModeItems: [DesktopVideoContentMode: NSMenuItem] = [:]
    private let localization: AppLocalizationController
    private var localizationCancellable: AnyCancellable?

    init(localization: AppLocalizationController) {
        self.localization = localization
        super.init()
        localizationCancellable = localization.localizationDidChange.sink {
            [weak self] in
            self?.updateMenu()
        }
    }

    @discardableResult
    func show() -> Bool {
        if let statusItem {
            guard isUsable(statusItem) else {
                remove()
                return createStatusItem()
            }
            return true
        }

        return createStatusItem()
    }

    private func createStatusItem() -> Bool {
        guard let image = makeMenuBarImage() else {
            return false
        }

        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        guard let button = statusItem.button else {
            NSStatusBar.system.removeStatusItem(statusItem)
            return false
        }
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = localized("app.name")
        button.setAccessibilityLabel(localized("app.name"))

        let menu = makeMenu()
        statusItem.menu = menu
        statusItem.isVisible = true
        statusItem.button?.setAccessibilityIdentifier(
            MuralumeAccessibilityIdentifier.desktopStatusItem
        )
        self.statusItem = statusItem
        updateMenu()

        guard isUsable(statusItem) else {
            remove()
            return false
        }
        return true
    }

    private func isUsable(_ statusItem: NSStatusItem) -> Bool {
        statusItem.button?.image != nil
            && statusItem.menu != nil
            && statusItem.isVisible
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let currentItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        currentItem.isEnabled = false
        menu.addItem(currentItem)

        let togglePlaybackItem = NSMenuItem(
            title: "",
            action: #selector(togglePlayback),
            keyEquivalent: ""
        )
        togglePlaybackItem.target = self
        menu.addItem(togglePlaybackItem)

        let playNextItem = NSMenuItem(
            title: localized("desktop.playNext"),
            action: #selector(playNext),
            keyEquivalent: ""
        )
        playNextItem.target = self
        menu.addItem(playNextItem)

        let playbackModeItem = makePlaybackModeItem()
        menu.addItem(playbackModeItem)

        let playbackRateItem = makePlaybackRateItem()
        menu.addItem(playbackRateItem)

        let videoContentModeItem = makeVideoContentModeItem()
        menu.addItem(videoContentModeItem)

        let returnItem = NSMenuItem(
            title: localized("desktop.return"),
            action: #selector(returnToPlayer),
            keyEquivalent: ""
        )
        returnItem.target = self
        menu.addItem(returnItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: localized("desktop.quit"),
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        self.currentItem = currentItem
        self.togglePlaybackItem = togglePlaybackItem
        self.playNextItem = playNextItem
        self.playbackModeItem = playbackModeItem
        self.playbackRateItem = playbackRateItem
        self.videoContentModeItem = videoContentModeItem
        self.returnItem = returnItem
        self.quitItem = quitItem
        return menu
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        currentItem = nil
        togglePlaybackItem = nil
        playNextItem = nil
        playbackModeItem = nil
        playbackModeItems.removeAll()
        playbackRateItem = nil
        playbackRateItems.removeAll()
        videoContentModeItem = nil
        videoContentModeItems.removeAll()
        returnItem = nil
        quitItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenu()
    }

    @objc
    private func togglePlayback() {
        togglePlaybackHandler?()
        updateMenu()
    }

    @objc
    private func playNext() {
        playNextHandler?()
        updateMenu()
    }

    @objc
    private func selectPlaybackMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = PlaybackMode(rawValue: rawValue) else {
            return
        }
        if let setPlaybackModeHandler {
            setPlaybackModeHandler(mode)
        } else {
            switch mode {
            case .ordered:
                setPlaybackOrderHandler?(.ordered)
            case .shuffled:
                setPlaybackOrderHandler?(.shuffled)
            case .repeatCurrent:
                break
            }
        }
        updateMenu()
    }

    @objc
    private func selectPlaybackRate(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else {
            return
        }
        setPlaybackRateHandler?(
            PlaybackRate(rawValue: value.floatValue)
        )
        updateMenu()
    }

    @objc
    private func returnToPlayer() {
        returnToPlayerHandler?()
    }

    @objc
    private func selectVideoContentMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let contentMode = DesktopVideoContentMode(rawValue: rawValue) else {
            return
        }
        setVideoContentModeHandler?(contentMode)
        updateMenu()
    }

    @objc
    private func quitApplication() {
        quitHandler?()
    }

    private func updateMenu() {
        let state = stateProvider?()
        if let state {
            let fullCurrentTitle = String(
                format: localized("desktop.current"),
                locale: localization.locale,
                state.sourceName
            )
            currentItem?.title = currentPlaybackTitle(
                sourceName: state.sourceName
            )
            currentItem?.toolTip = fullCurrentTitle
            currentItem?.setAccessibilityLabel(fullCurrentTitle)
            togglePlaybackItem?.title = localized(
                state.isPlaying ? "desktop.pause" : "desktop.resume"
            )
            togglePlaybackItem?.isEnabled = !state.isTransitioning
            playNextItem?.isEnabled = state.canPlayNext
                && !state.isTransitioning
            playbackModeItem?.isEnabled = state.canSetPlaybackOrder
                && !state.isTransitioning
            playbackRateItem?.isEnabled = !state.isTransitioning
            videoContentModeItem?.isEnabled = !state.isTransitioning
            returnItem?.isEnabled = !state.isTransitioning
        }

        playNextItem?.title = localized("desktop.playNext")
        playbackModeItem?.title = localized("queue.mode")
        playbackModeItem?.submenu?.title = localized("queue.mode")
        for (mode, item) in playbackModeItems {
            item.title = localized(mode.desktopStatusLocalizedKey)
            if let state {
                item.state = mode == state.playbackMode ? .on : .off
            }
        }
        playbackRateItem?.title = localized("player.speed")
        playbackRateItem?.submenu?.title = localized("player.speed")
        for (rate, item) in playbackRateItems {
            item.title = PlayerFormatting.rate(rate)
            if let state {
                item.state = rate == state.playbackRate ? .on : .off
            }
        }
        videoContentModeItem?.title = localized("desktop.contentMode")
        videoContentModeItem?.submenu?.title = localized(
            "desktop.contentMode"
        )
        for (contentMode, item) in videoContentModeItems {
            item.title = localized(contentMode.localizedKey)
            if let state {
                item.state = contentMode == state.videoContentMode ? .on : .off
            }
        }
        returnItem?.title = localized("desktop.return")
        quitItem?.title = localized("desktop.quit")
        statusItem?.button?.toolTip = localized("app.name")
        statusItem?.button?.setAccessibilityLabel(localized("app.name"))
    }

    private func currentPlaybackTitle(sourceName: String) -> String {
        let format = localized("desktop.current")
        let font = NSFont.menuFont(ofSize: 0)
        let fullTitle = formattedCurrentPlaybackTitle(
            format: format,
            sourceName: sourceName
        )
        guard textWidth(fullTitle, font: font)
                > DesktopStatusMenuLayout.currentPlaybackMaximumWidth else {
            return fullTitle
        }

        let characters = Array(sourceName)
        let marker = DesktopStatusMenuLayout.truncationMarker
        var lowerBound = 0
        var upperBound = characters.count
        while lowerBound < upperBound {
            let keptCharacterCount = (lowerBound + upperBound + 1) / 2
            let candidateSourceName = middleTruncationCandidate(
                characters,
                keptCharacterCount: keptCharacterCount,
                marker: marker
            )
            let candidateTitle = formattedCurrentPlaybackTitle(
                format: format,
                sourceName: candidateSourceName
            )
            if textWidth(candidateTitle, font: font)
                <= DesktopStatusMenuLayout.currentPlaybackMaximumWidth {
                lowerBound = keptCharacterCount
            } else {
                upperBound = keptCharacterCount - 1
            }
        }

        let visibleSourceName = middleTruncationCandidate(
            characters,
            keptCharacterCount: lowerBound,
            marker: marker
        )
        return formattedCurrentPlaybackTitle(
            format: format,
            sourceName: visibleSourceName
        )
    }

    private func formattedCurrentPlaybackTitle(
        format: String,
        sourceName: String
    ) -> String {
        String(
            format: format,
            locale: localization.locale,
            sourceName
        )
    }

    private func middleTruncationCandidate(
        _ characters: [Character],
        keptCharacterCount: Int,
        marker: String
    ) -> String {
        let prefixCount = (keptCharacterCount + 1) / 2
        let suffixCount = keptCharacterCount / 2
        return String(characters.prefix(prefixCount))
            + marker
            + String(characters.suffix(suffixCount))
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(
            (text as NSString).size(
                withAttributes: [.font: font]
            ).width
        )
    }

    private func makePlaybackRateItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: localized("player.speed"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: localized("player.speed"))

        for rate in PlaybackPolicy.supportedRates {
            let rateItem = NSMenuItem(
                title: PlayerFormatting.rate(rate),
                action: #selector(selectPlaybackRate(_:)),
                keyEquivalent: ""
            )
            rateItem.target = self
            rateItem.representedObject = NSNumber(value: rate.rawValue)
            submenu.addItem(rateItem)
            playbackRateItems[rate] = rateItem
        }

        item.submenu = submenu
        return item
    }

    private func makePlaybackModeItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: localized("queue.mode"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: localized("queue.mode"))

        for mode in DesktopPlaybackModeMenu.displayOrder {
            let modeItem = NSMenuItem(
                title: localized(mode.desktopStatusLocalizedKey),
                action: #selector(selectPlaybackMode(_:)),
                keyEquivalent: ""
            )
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            submenu.addItem(modeItem)
            playbackModeItems[mode] = modeItem
        }

        item.submenu = submenu
        return item
    }

    private func makeVideoContentModeItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: localized("desktop.contentMode"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: localized("desktop.contentMode"))

        for contentMode in DesktopVideoContentMode.allCases {
            let contentModeItem = NSMenuItem(
                title: localized(contentMode.localizedKey),
                action: #selector(selectVideoContentMode(_:)),
                keyEquivalent: ""
            )
            contentModeItem.target = self
            contentModeItem.representedObject = contentMode.rawValue
            submenu.addItem(contentModeItem)
            videoContentModeItems[contentMode] = contentModeItem
        }

        item.submenu = submenu
        return item
    }

    func makeMenuBarImage() -> NSImage? {
        guard let sourceImage = NSImage(named: DesktopStatusMenuAsset.menuBarMark),
              let image = sourceImage.copy() as? NSImage else {
            return nil
        }
        image.size = DesktopStatusMenuLayout.iconSize
        image.isTemplate = true
        return image
    }

    private func localized(_ key: String) -> String {
        localization.localized(key)
    }
}
