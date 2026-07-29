import AppKit
import Combine

private enum DesktopStatusMenuLayout {
    static let iconSize = NSSize(width: 18, height: 18)
}

private enum DesktopStatusMenuAsset {
    static let menuBarMark = NSImage.Name("MenuBarMark")
}

@MainActor
final class DesktopStatusMenuController: NSObject, NSMenuDelegate, DesktopStatusPresenting {
    var stateProvider: (() -> DesktopStatusState)?
    var togglePlaybackHandler: (() -> Void)?
    var playNextHandler: (() -> Void)?
    var setPlaybackRateHandler: ((PlaybackRate) -> Void)?
    var returnToPlayerHandler: (() -> Void)?
    var setVideoContentModeHandler: ((DesktopVideoContentMode) -> Void)?
    var quitHandler: (() -> Void)?

    private var statusItem: NSStatusItem?
    private weak var currentItem: NSMenuItem?
    private weak var togglePlaybackItem: NSMenuItem?
    private weak var playNextItem: NSMenuItem?
    private weak var playbackRateItem: NSMenuItem?
    private weak var videoContentModeItem: NSMenuItem?
    private weak var returnItem: NSMenuItem?
    private weak var quitItem: NSMenuItem?
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

    func show() {
        guard statusItem == nil else {
            return
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = makeMenuBarImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = localized("app.name")
            button.setAccessibilityLabel(localized("app.name"))
        }

        let menu = makeMenu()
        statusItem.menu = menu
        self.statusItem = statusItem
        updateMenu()
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
            currentItem?.title = String(
                format: localized("desktop.current"),
                locale: localization.locale,
                state.sourceName
            )
            togglePlaybackItem?.title = localized(
                state.isPlaying ? "desktop.pause" : "desktop.resume"
            )
            togglePlaybackItem?.isEnabled = !state.isTransitioning
            playNextItem?.isEnabled = state.canPlayNext
                && !state.isTransitioning
            playbackRateItem?.isEnabled = !state.isTransitioning
            videoContentModeItem?.isEnabled = !state.isTransitioning
            returnItem?.isEnabled = !state.isTransitioning
        }

        playNextItem?.title = localized("desktop.playNext")
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
