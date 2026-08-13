import SwiftUI

struct DesktopEntryControl: View {
    let actionLabelKey: String
    let isEnabled: Bool
    let showsOptions: Bool
    let enterDesktop: () -> Void
    let enterDesktopSynchronized: () -> Void
    let presentDesktopLayout: () -> Void

    static func showsOptions(
        forConnectedDisplayCount connectedDisplayCount: Int
    ) -> Bool {
        connectedDisplayCount > 1
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: enterDesktop) {
                Image(systemName: "display")
            }
            .buttonStyle(
                DesktopEntrySegmentButtonStyle(
                    width: MuralumeTheme.Size.control
                )
            )
            .help(Text(LocalizedStringKey(actionLabelKey)))
            .accessibilityLabel(
                Text(LocalizedStringKey(actionLabelKey))
            )
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.enterDesktopButton
            )
            .disabled(!isEnabled)

            if showsOptions {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(
                        width: 1,
                        height: MuralumeTheme.Size.iconLarge
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                Menu {
                    Button(action: enterDesktopSynchronized) {
                        Label(
                            "player.desktop.syncAll",
                            systemImage: "rectangle.on.rectangle"
                        )
                    }

                    Divider()

                    Button(action: presentDesktopLayout) {
                        Label(
                            "player.desktop.customize",
                            systemImage: "rectangle.3.group"
                        )
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(
                            width: MuralumeTheme.Size.desktopEntryOptionsWidth,
                            height: MuralumeTheme.Size.control
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("player.desktop.options"))
                .accessibilityLabel(Text("player.desktop.options"))
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.desktopEntryOptionsButton
                )
                .disabled(!isEnabled)
            }
        }
        .background(MuralumeTheme.brandGradient)
        .clipShape(
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
            .stroke(Color.white.opacity(0.18), lineWidth: 1)
            .allowsHitTesting(false)
        }
        .opacity(isEnabled ? 1 : 0.34)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

private struct DesktopEntrySegmentButtonStyle: ButtonStyle {
    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(
                .system(
                    size: MuralumeTheme.Size.icon,
                    weight: .semibold
                )
            )
            .foregroundStyle(Color.white)
            .frame(width: width, height: MuralumeTheme.Size.control)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.12 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
