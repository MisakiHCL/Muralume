import AppKit
import SwiftUI

struct PlayerTopBar: View {
    @ObservedObject var playback: PlaybackCoordinator
    let isFullScreen: Bool
    let actions: PlayerActions

    @Environment(\.locale) private var locale

    var body: some View {
        ZStack {
            HStack(spacing: MuralumeTheme.Spacing.medium) {
                MuralumeWindowControls(
                    actions: actions,
                    labels: windowControlLabels,
                    isFullScreen: isFullScreen
                )
                .frame(
                    width: MuralumeTheme.Size.windowControlClusterWidth,
                    height: MuralumeTheme.Size.playerTopBarHeight
                )

                brand

                Spacer(minLength: MuralumeTheme.Spacing.medium)

                settings
            }

            if let source = playback.source {
                currentSource(source.displayName)
            }
        }
        .padding(.horizontal, MuralumeTheme.Spacing.medium)
        .frame(maxWidth: .infinity)
        .frame(height: MuralumeTheme.Size.playerTopBarHeight)
        .muralumePlayerTopChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playerTopBar
        )
    }

    private var windowControlLabels: MuralumeWindowControlLabels {
        MuralumeWindowControlLabels(
            close: String(
                localized: "window.close",
                bundle: .main,
                locale: locale
            ),
            minimize: String(
                localized: "window.minimize",
                bundle: .main,
                locale: locale
            ),
            fullScreen: String(
                localized: "player.fullscreen",
                bundle: .main,
                locale: locale
            )
        )
    }

    private var brand: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            MuralumeBrandMark(
                size: MuralumeTheme.Size.playerTopBarBrandMark
            )

            Text("app.name")
                .font(.headline.weight(.bold))
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("app.name"))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.brandMark
        )
    }

    private var settings: some View {
        Button(action: actions.openSettings) {
            Image(systemName: "gearshape")
        }
        .buttonStyle(
            MuralumeControlButtonStyle(scale: .compact)
        )
        .help(Text("settings.open"))
        .accessibilityLabel(Text("settings.open"))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.openSettingsButton
        )
    }

    private func currentSource(_ displayName: String) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: MuralumeTheme.Size.icon))
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)

            Text(verbatim: displayName)
                .font(.body.weight(.medium))
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, MuralumeTheme.Spacing.small)
        .frame(height: MuralumeTheme.Size.playerTopBarSourceHeight)
        .frame(maxWidth: MuralumeTheme.Size.playerTopBarSourceMaximumWidth)
        .accessibilityElement(children: .combine)
    }
}

private struct MuralumeWindowControlLabels {
    let close: String
    let minimize: String
    let fullScreen: String
}

private struct MuralumeWindowControls: NSViewRepresentable {
    let actions: PlayerActions
    let labels: MuralumeWindowControlLabels
    let isFullScreen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeNSView(context: Context) -> NativeWindowControlsView {
        let view = NativeWindowControlsView()
        view.configure(target: context.coordinator)
        view.update(
            labels: labels,
            isFullScreen: isFullScreen
        )
        return view
    }

    func updateNSView(
        _ nsView: NativeWindowControlsView,
        context: Context
    ) {
        context.coordinator.actions = actions
        nsView.update(
            labels: labels,
            isFullScreen: isFullScreen
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var actions: PlayerActions

        init(actions: PlayerActions) {
            self.actions = actions
        }

        @objc
        func closeWindow() {
            actions.closeWindow()
        }

        @objc
        func minimizeWindow() {
            actions.minimizeWindow()
        }

        @objc
        func toggleFullScreen() {
            actions.toggleFullScreen()
        }
    }
}

@MainActor
private final class NativeWindowControlsView: NSView {
    private enum Layout {
        static let controlSpacing: CGFloat = 8
    }

    private let closeButton = NativeWindowControlsView.makeButton(
        type: .closeButton,
        accessibilityIdentifier:
            MuralumeAccessibilityIdentifier.closeWindowButton
    )
    private let minimizeButton = NativeWindowControlsView.makeButton(
        type: .miniaturizeButton,
        accessibilityIdentifier:
            MuralumeAccessibilityIdentifier.minimizeWindowButton
    )
    private let fullScreenButton = NativeWindowControlsView.makeButton(
        type: .zoomButton,
        accessibilityIdentifier:
            MuralumeAccessibilityIdentifier.fullScreenWindowButton
    )

    private var buttons: [NSButton] {
        [closeButton, minimizeButton, fullScreenButton]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buttons.forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let buttonWidth = closeButton.intrinsicContentSize.width
        let buttonHeight = closeButton.intrinsicContentSize.height
        let clusterWidth = buttonWidth * CGFloat(buttons.count)
            + Layout.controlSpacing * CGFloat(buttons.count - 1)
        var originX = (bounds.width - clusterWidth) / 2
        let originY = (bounds.height - buttonHeight) / 2

        for button in buttons {
            button.frame = NSRect(
                x: originX,
                y: originY,
                width: buttonWidth,
                height: buttonHeight
            )
            originX += buttonWidth + Layout.controlSpacing
        }
    }

    func configure(target: MuralumeWindowControls.Coordinator) {
        closeButton.target = target
        closeButton.action = #selector(target.closeWindow)
        minimizeButton.target = target
        minimizeButton.action = #selector(target.minimizeWindow)
        fullScreenButton.target = target
        fullScreenButton.action = #selector(target.toggleFullScreen)
    }

    func update(
        labels: MuralumeWindowControlLabels,
        isFullScreen: Bool
    ) {
        update(closeButton, label: labels.close)
        update(minimizeButton, label: labels.minimize)
        update(fullScreenButton, label: labels.fullScreen)
        closeButton.isEnabled = true
        minimizeButton.isEnabled = !isFullScreen
        fullScreenButton.isEnabled = true
    }

    private func update(_ button: NSButton, label: String) {
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private static func makeButton(
        type: NSWindow.ButtonType,
        accessibilityIdentifier: String
    ) -> NSButton {
        let button = NSWindow.standardWindowButton(
            type,
            for: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable
            ]
        ) ?? NSButton()
        button.setAccessibilityRole(.button)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        return button
    }
}
