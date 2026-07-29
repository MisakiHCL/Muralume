import AppKit
import SwiftUI

enum MuralumeTheme {
    enum Colors {
        static let window = Color(red: 10 / 255, green: 10 / 255, blue: 14 / 255)
        static let canvas = Color(red: 4 / 255, green: 4 / 255, blue: 6 / 255)
        static let panel = Color(red: 18 / 255, green: 18 / 255, blue: 24 / 255)
        static let panelRaised = Color(red: 28 / 255, green: 28 / 255, blue: 36 / 255)
        static let accent = Color(
            red: 124 / 255,
            green: 58 / 255,
            blue: 237 / 255
        )
        static let accentSecondary = Color(
            red: 146 / 255,
            green: 82 / 255,
            blue: 232 / 255
        )
        static let controlAccent = Color.white.opacity(0.72)
        static let textPrimary = Color.white.opacity(0.94)
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.42)
        static let border = Color.white.opacity(0.11)
        static let borderStrong = Color.white.opacity(0.18)
        static let controlFill = Color.white.opacity(0.07)
        static let controlHover = Color.white.opacity(0.12)
        static let warning = Color(red: 1, green: 185 / 255, blue: 92 / 255)
        static let error = Color(red: 1, green: 110 / 255, blue: 120 / 255)

        static let windowNSColor = NSColor(
            red: 10 / 255,
            green: 10 / 255,
            blue: 14 / 255,
            alpha: 1
        )
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 32
        static let hero: CGFloat = 48
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 20
    }

    enum Size {
        static let toolbarBrandMark: CGFloat = 28
        static let settingsBrandMark: CGFloat = 48
        static let emptyBrandMark: CGFloat = 88
        static let icon: CGFloat = 16
        static let iconLarge: CGFloat = 20
        static let menuIndicator: CGFloat = 12
        static let control: CGFloat = 36
        static let primaryControl: CGFloat = 44
        static let videoMinimumHeight: CGFloat = 360
        static let volumeSliderWidth: CGFloat = 104
        static let playlistOverlayWidth: CGFloat = 320
        static let playerControlsMaximumWidth: CGFloat = 1_040
        static let widePlayerControlsMinimumWidth: CGFloat = 1_000
        static let playerControlsReservedHeight: CGFloat = 136
        static let playlistRowHeight: CGFloat = 72
        static let playlistArtworkWidth: CGFloat = 84
        static let playlistArtworkHeight: CGFloat = 48
        static let queueFooterHeight: CGFloat = 36
        static let toolbarSourceHeight: CGFloat = 28
    }

    enum Motion {
        static let playerChromeTransitionDuration: TimeInterval = 0.18
        static let playerChromeAutoHideNanoseconds: UInt64 = 2_500_000_000
    }

    enum Glass {
        static let standardTintOpacity = 0.58
        static let playerOverlayTintOpacity = 0.28
    }

    enum Shadow {
        static let panelRadius: CGFloat = 24
        static let glowRadius: CGFloat = 32
        static let panelY: CGFloat = 12
    }

    static let brandGradient = LinearGradient(
        colors: [Colors.accent, Colors.accentSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let brandHighlightGradient = LinearGradient(
        colors: [Colors.accentSecondary, Colors.accent],
        startPoint: .leading,
        endPoint: .trailing
    )
}

enum MuralumeAsset {
    static let brandMark = "BrandMark"
    static let menuBarMark = "MenuBarMark"
}

enum MuralumeAccessibilityIdentifier {
    static let brandMark = "muralume.brand-mark"
    static let videoViewport = "muralume.video-viewport"
    static let playerControls = "muralume.player-controls"
    static let playbackTimeline = "muralume.playback-timeline"
    static let playerControlBar = "muralume.player-control-bar"
    static let playerTransportControls = "muralume.player-transport-controls"
    static let playlistToggleButton = "muralume.playlist-toggle"
    static let librarySidebar = "muralume.library-sidebar"
    static let libraryTitle = "muralume.library-title"
    static let editLibraryButton = "muralume.edit-library"
    static let addFolderButton = "muralume.add-folder"
    static let playbackOrderButton = "muralume.playback-order"
    static let librarySortButton = "muralume.library-sort"
    static let openSettingsButton = "muralume.open-settings"
    static let settingsView = "muralume.settings-view"
    static let languagePicker = "muralume.language-picker"
}

struct MuralumeBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MuralumeTheme.Colors.window

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                MuralumeTheme.Colors.accent.opacity(0.08),
                                MuralumeTheme.Colors.accent.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: proxy.size.width * 0.3
                        )
                    )
                    .frame(
                        width: proxy.size.width * 0.72,
                        height: proxy.size.height * 0.6
                    )
                    .blur(radius: 96)
                    .offset(
                        x: -proxy.size.width * 0.28,
                        y: -proxy.size.height * 0.34
                    )

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                MuralumeTheme.Colors.accentSecondary.opacity(0.06),
                                MuralumeTheme.Colors.accentSecondary.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: proxy.size.width * 0.26
                        )
                    )
                    .frame(
                        width: proxy.size.width * 0.64,
                        height: proxy.size.height * 0.52
                    )
                    .blur(radius: 112)
                    .offset(
                        x: proxy.size.width * 0.34,
                        y: proxy.size.height * 0.34
                    )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct MuralumeBrandMark: View {
    let size: CGFloat

    var body: some View {
        Image(MuralumeAsset.brandMark)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum MuralumePanelStyle {
    case standard
    case playerOverlay

    fileprivate var tintOpacity: Double {
        switch self {
        case .standard:
            MuralumeTheme.Glass.standardTintOpacity
        case .playerOverlay:
            MuralumeTheme.Glass.playerOverlayTintOpacity
        }
    }
}

private struct MuralumePanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat
    let style: MuralumePanelStyle

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        Group {
            if reduceTransparency {
                shape.fill(MuralumeTheme.Colors.panel)
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(
                        shape.fill(
                            MuralumeTheme.Colors.panel.opacity(
                                style.tintOpacity
                            )
                        )
                    )
            }
        }
        .overlay(shape.stroke(MuralumeTheme.Colors.border, lineWidth: 1))
        .shadow(
            color: Color.black.opacity(0.32),
            radius: MuralumeTheme.Shadow.panelRadius,
            y: MuralumeTheme.Shadow.panelY
        )
    }
}

extension View {
    func muralumePanel(
        cornerRadius: CGFloat = MuralumeTheme.Radius.large,
        style: MuralumePanelStyle = .standard
    ) -> some View {
        background {
            MuralumePanelBackground(
                cornerRadius: cornerRadius,
                style: style
            )
        }
    }
}

struct MuralumeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(MuralumeTheme.Colors.textPrimary)
            .padding(.horizontal, MuralumeTheme.Spacing.large)
            .frame(height: 40)
            .background {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .fill(
                    configuration.isPressed
                        ? MuralumeTheme.Colors.controlHover
                        : MuralumeTheme.Colors.controlFill
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: MuralumeTheme.Radius.medium,
                        style: .continuous
                    )
                    .stroke(MuralumeTheme.Colors.borderStrong, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.38)
    }
}

struct MuralumeBrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, MuralumeTheme.Spacing.large)
            .frame(height: 40)
            .background {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .fill(MuralumeTheme.brandGradient)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: MuralumeTheme.Radius.medium,
                        style: .continuous
                    )
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
            }
            .shadow(
                color: MuralumeTheme.Colors.accent.opacity(
                    configuration.isPressed ? 0.16 : 0.28
                ),
                radius: configuration.isPressed ? 8 : 16,
                y: 4
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.38)
    }
}

struct MuralumeControlButtonStyle: ButtonStyle {
    enum Kind {
        case standard
        case selected
        case prominent
        case accent
    }

    @Environment(\.isEnabled) private var isEnabled

    let kind: Kind

    init(kind: Kind = .standard) {
        self.kind = kind
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .frame(width: controlSize, height: controlSize)
            .background {
                controlBackground(isPressed: configuration.isPressed)
            }
            .contentShape(
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.34)
    }

    @ViewBuilder
    private func controlBackground(isPressed: Bool) -> some View {
        switch kind {
        case .standard, .selected:
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .fill(
                kind == .selected || isPressed
                    ? MuralumeTheme.Colors.controlHover
                    : MuralumeTheme.Colors.controlFill
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(
                    kind == .selected
                        ? MuralumeTheme.Colors.borderStrong
                        : MuralumeTheme.Colors.border,
                    lineWidth: 1
                )
            }
        case .prominent:
            Circle()
                .fill(MuralumeTheme.brandGradient)
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(
                    color: MuralumeTheme.Colors.accent.opacity(0.3),
                    radius: MuralumeTheme.Shadow.glowRadius / 2,
                    y: MuralumeTheme.Spacing.xSmall
                )
        case .accent:
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .fill(MuralumeTheme.brandGradient)
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
        }
    }

    private var controlSize: CGFloat {
        kind == .prominent
            ? MuralumeTheme.Size.primaryControl
            : MuralumeTheme.Size.control
    }

    private var iconSize: CGFloat {
        kind == .prominent
            ? MuralumeTheme.Size.iconLarge
            : MuralumeTheme.Size.icon
    }

    private var cornerRadius: CGFloat {
        kind == .prominent
            ? MuralumeTheme.Size.primaryControl / 2
            : MuralumeTheme.Radius.medium
    }

    private var foregroundColor: Color {
        kind == .standard || kind == .selected
            ? MuralumeTheme.Colors.textPrimary
            : .white
    }
}
