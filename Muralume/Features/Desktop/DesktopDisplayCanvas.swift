import AppKit
import SwiftUI

struct DesktopDisplayCanvasLayout {
    struct PositionedDisplay: Equatable, Identifiable {
        let id: DesktopDisplayID
        let number: Int
        let frame: CGRect
    }

    static func positions(
        for displays: [DesktopDisplayDescriptor],
        in canvasSize: CGSize,
        padding: CGFloat = MuralumeTheme.Spacing.medium
    ) -> [PositionedDisplay] {
        guard !displays.isEmpty,
              canvasSize.width > padding * 2,
              canvasSize.height > padding * 2 else {
            return []
        }

        let sourceFrames = displays.map { normalized($0.frame) }
        let sourceBounds = sourceFrames.dropFirst().reduce(
            sourceFrames[0]
        ) { bounds, frame in
            bounds.union(frame)
        }
        guard sourceBounds.width > 0, sourceBounds.height > 0 else {
            return []
        }

        let availableSize = CGSize(
            width: canvasSize.width - padding * 2,
            height: canvasSize.height - padding * 2
        )
        let scale = min(
            availableSize.width / sourceBounds.width,
            availableSize.height / sourceBounds.height
        )
        let renderedSize = CGSize(
            width: sourceBounds.width * scale,
            height: sourceBounds.height * scale
        )
        let origin = CGPoint(
            x: (canvasSize.width - renderedSize.width) / 2,
            y: (canvasSize.height - renderedSize.height) / 2
        )

        return zip(displays, sourceFrames).enumerated().map {
            index,
            pair in
            let (display, sourceFrame) = pair
            let x = origin.x
                + (sourceFrame.minX - sourceBounds.minX) * scale
            // AppKit display frames grow upward. SwiftUI's local coordinates
            // grow downward, so mirror the vertical component here.
            let y = origin.y
                + (sourceBounds.maxY - sourceFrame.maxY) * scale
            return PositionedDisplay(
                id: display.id,
                number: index + 1,
                frame: CGRect(
                    x: x,
                    y: y,
                    width: sourceFrame.width * scale,
                    height: sourceFrame.height * scale
                )
            )
        }
    }

    private static func normalized(_ frame: CGRect) -> CGRect {
        let standardized = frame.standardized
        guard standardized.width > 0, standardized.height > 0 else {
            return CGRect(
                x: standardized.minX,
                y: standardized.minY,
                width: 1,
                height: 1
            )
        }
        return standardized
    }
}

struct DesktopDisplayCanvas: View {
    let displays: [DesktopDisplayDescriptor]
    let scene: DesktopScene
    let currentItem: LibraryMediaItem?
    let itemsByID: [LibraryMediaItem.ID: LibraryMediaItem]
    let selectedDisplayID: DesktopDisplayID?
    let selectDisplay: (DesktopDisplayID) -> Void
    let identifyDisplays: () -> Void

    @EnvironmentObject private var localization: AppLocalizationController

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.small) {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Text("desktop.layout.accessibility.arrangement")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)

                Spacer(minLength: MuralumeTheme.Spacing.medium)

                Button(action: identify) {
                    Label(
                        "desktop.layout.identify",
                        systemImage: "rectangle.inset.filled.and.person.filled"
                    )
                }
                .buttonStyle(MuralumeToolbarButtonStyle())
                .help(Text("desktop.layout.identify.hint"))
                .accessibilityHint(Text("desktop.layout.identify.hint"))
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.desktopIdentifyButton
                )
            }

            GeometryReader { proxy in
                let positions = DesktopDisplayCanvasLayout.positions(
                    for: displays,
                    in: proxy.size
                )

                ZStack(alignment: .topLeading) {
                    ForEach(positions) { position in
                        if let display = displays.first(where: {
                            $0.id == position.id
                        }) {
                            displayCard(
                                display,
                                position: position
                            )
                        }
                    }
                }
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .topLeading
                )
            }
        }
        .padding(MuralumeTheme.Spacing.medium)
        .frame(height: MuralumeTheme.Size.desktopDisplayCanvasHeight)
        .background {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
            .fill(MuralumeTheme.Colors.canvas.opacity(0.72))
            .overlay {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text("desktop.layout.accessibility.arrangement")
        )
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.desktopDisplayCanvas
        )
    }

    private func displayCard(
        _ display: DesktopDisplayDescriptor,
        position: DesktopDisplayCanvasLayout.PositionedDisplay
    ) -> some View {
        let assignment = scene.assignment(for: display.id)
        let isEnabled = assignment?.isEnabled == true
        let isSelected = selectedDisplayID == display.id

        return Button {
            selectDisplay(display.id)
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.small,
                    style: .continuous
                )
                .fill(
                    isEnabled
                        ? MuralumeTheme.Colors.panelRaised
                        : MuralumeTheme.Colors.panel.opacity(0.78)
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: MuralumeTheme.Radius.small,
                        style: .continuous
                    )
                    .stroke(
                        isSelected
                            ? MuralumeTheme.Colors.accentSecondary
                            : MuralumeTheme.Colors.borderStrong,
                        lineWidth: isSelected ? 2 : 1
                    )
                }

                VStack(spacing: MuralumeTheme.Spacing.xSmall) {
                    Spacer(minLength: MuralumeTheme.Spacing.xSmall)

                    Text(verbatim: display.localizedName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            isEnabled
                                ? MuralumeTheme.Colors.textPrimary
                                : MuralumeTheme.Colors.textTertiary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if display.isMain {
                        Text("desktop.layout.mainDisplay")
                            .font(.caption2)
                            .foregroundStyle(
                                MuralumeTheme.Colors.textSecondary
                            )
                            .lineLimit(1)
                    }

                    Spacer(minLength: MuralumeTheme.Spacing.xSmall)
                }
                .padding(.horizontal, MuralumeTheme.Spacing.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(verbatim: String(position.number))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(
                        width: MuralumeTheme.Size.desktopDisplayNumberBadge,
                        height: MuralumeTheme.Size.desktopDisplayNumberBadge
                    )
                    .background(
                        Circle().fill(
                            isSelected
                                ? MuralumeTheme.Colors.accentSecondary
                                : MuralumeTheme.Colors.controlFill
                        )
                    )
                    .padding(MuralumeTheme.Spacing.xSmall)
            }
            .contentShape(
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.small,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .frame(
            width: position.frame.width,
            height: position.frame.height
        )
        .offset(x: position.frame.minX, y: position.frame.minY)
        .opacity(isEnabled ? 1 : 0.7)
        .accessibilityLabel(
            Text(
                verbatim: accessibilityLabel(
                    for: display,
                    number: position.number,
                    assignment: assignment
                )
            )
        )
        .accessibilityHint(
            Text("desktop.layout.accessibility.displayCard.hint")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityLabel(
        for display: DesktopDisplayDescriptor,
        number: Int,
        assignment: DesktopDisplayAssignment?
    ) -> String {
        let isEnabled = assignment?.isEnabled == true
        let enabledStatus = localization.localized(
            isEnabled
                ? "desktop.layout.accessibility.enabled"
                : "desktop.layout.accessibility.disabled"
        )
        let mediaName = mediaName(for: assignment)
        let resolvedContentMode = scene.mode == .synchronized
            ? scene.defaultContentMode
            : assignment?.contentMode ?? scene.defaultContentMode
        let contentMode = localization.localized(
            resolvedContentMode.localizedKey
        )
        return localization.localizedFormat(
            "desktop.layout.accessibility.displayCard",
            number,
            display.localizedName,
            enabledStatus,
            mediaName,
            contentMode
        )
    }

    private func mediaName(
        for assignment: DesktopDisplayAssignment?
    ) -> String {
        switch scene.mode {
        case .synchronized:
            return currentItem?.displayName
                ?? localization.localized("desktop.layout.noVideo")
        case .perDisplay:
            guard let itemID = assignment?.mediaItemID else {
                return localization.localized("desktop.layout.noVideo")
            }
            return itemsByID[itemID]?.displayName
                ?? localization.localized("desktop.layout.noVideo")
        }
    }

    private func identify() {
        identifyDisplays()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: localization.localized(
                    "desktop.layout.identify.announcement"
                ),
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
