import SwiftUI

struct DesktopLayoutView: View {
    @ObservedObject var desktopScene: DesktopSceneController

    let items: [LibraryMediaItem]
    let currentItem: LibraryMediaItem?
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let cancel: () -> Void
    let apply: () -> Void

    @EnvironmentObject private var localization: AppLocalizationController

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.large) {
            header

            ScrollView {
                VStack(spacing: MuralumeTheme.Spacing.medium) {
                    modePicker

                    DesktopDisplayCanvas(
                        displays: desktopScene.connectedDisplays,
                        scene: desktopScene.scene,
                        currentItem: currentItem,
                        itemsByID: itemsByID,
                        selectedDisplayID:
                            desktopScene.selectedDisplayID,
                        selectDisplay: desktopScene.select,
                        identifyDisplays: desktopScene.identifyDisplays
                    )

                    displayInspector

                    notices
                }
            }
            .scrollIndicators(.automatic)

            Divider()

            footer
        }
        .padding(MuralumeTheme.Spacing.xLarge)
        .frame(
            maxWidth: MuralumeTheme.Size.desktopLayoutMaximumWidth,
            maxHeight: MuralumeTheme.Size.desktopLayoutMaximumHeight
        )
        .muralumePanel(style: .standard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.desktopLayoutView
        )
        .onAppear {
            desktopScene.beginEditing()
        }
        .onExitCommand(perform: cancel)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: MuralumeTheme.Spacing.large) {
            VStack(
                alignment: .leading,
                spacing: MuralumeTheme.Spacing.xSmall
            ) {
                Text("desktop.layout.title")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(MuralumeTheme.Colors.textPrimary)

                Text("desktop.layout.detail")
                    .font(.callout)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            }

            Spacer(minLength: MuralumeTheme.Spacing.large)

            Button(action: cancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(MuralumeControlButtonStyle(scale: .compact))
            .help(Text("desktop.layout.close"))
            .accessibilityLabel(Text("desktop.layout.close"))
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.desktopLayoutCloseButton
            )
        }
    }

    private var modePicker: some View {
        VStack(
            alignment: .leading,
            spacing: MuralumeTheme.Spacing.small
        ) {
            Text("desktop.layout.mode")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)

            Picker(
                "desktop.layout.mode",
                selection: Binding(
                    get: { desktopScene.scene.mode },
                    set: { mode in
                        desktopScene.setMode(mode)
                    }
                )
            ) {
                Text("desktop.layout.mode.synchronized")
                    .tag(DesktopSceneMode.synchronized)
                Text("desktop.layout.mode.independent")
                    .tag(DesktopSceneMode.perDisplay)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel(Text("desktop.layout.mode"))
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.desktopLayoutModePicker
            )
        }
    }

    @ViewBuilder
    private var displayInspector: some View {
        if let display = selectedDisplay,
           let assignment = desktopScene.selectedAssignment {
            VStack(
                alignment: .leading,
                spacing: MuralumeTheme.Spacing.medium
            ) {
                HStack(spacing: MuralumeTheme.Spacing.small) {
                    Text(verbatim: display.localizedName)
                        .font(.headline)
                        .lineLimit(1)

                    if display.isMain {
                        Text("desktop.layout.mainDisplay")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(
                                MuralumeTheme.Colors.textSecondary
                            )
                            .padding(
                                .horizontal,
                                MuralumeTheme.Spacing.small
                            )
                            .padding(
                                .vertical,
                                MuralumeTheme.Spacing.xSmall
                            )
                            .background(
                                Capsule().fill(
                                    MuralumeTheme.Colors.controlFill
                                )
                            )
                    }

                    Spacer(minLength: MuralumeTheme.Spacing.medium)

                    Toggle(
                        "desktop.layout.useDisplay",
                        isOn: enabledBinding(for: display.id)
                    )
                    .toggleStyle(.switch)
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier
                            .desktopDisplayEnabledToggle
                    )
                }

                Divider()

                HStack(
                    alignment: .top,
                    spacing: MuralumeTheme.Spacing.large
                ) {
                    contentModePicker(for: display.id)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if desktopScene.scene.mode == .synchronized {
                        currentVideoSummary
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                    } else {
                        DesktopMediaSelectionControl(
                            items: items,
                            selectedItem: assignment.mediaItemID.flatMap {
                                itemsByID[$0]
                            },
                            provider: mediaThumbnailProvider,
                            select: { item in
                                desktopScene.setMediaItem(
                                    item.id,
                                    for: display.id
                                )
                            }
                        )
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    }
                }
                .disabled(!assignment.isEnabled)
            }
            .padding(MuralumeTheme.Spacing.large)
            .background {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .fill(MuralumeTheme.Colors.controlFill)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: MuralumeTheme.Radius.medium,
                        style: .continuous
                    )
                    .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.desktopDisplayInspector
            )
        }
    }

    private func contentModePicker(
        for displayID: DesktopDisplayID
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: MuralumeTheme.Spacing.small
        ) {
            Text("desktop.contentMode")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)

            Picker(
                "desktop.contentMode",
                selection: contentModeBinding(for: displayID)
            ) {
                ForEach(DesktopVideoContentMode.allCases, id: \.self) {
                    contentMode in
                    Text(LocalizedStringKey(contentMode.localizedKey))
                        .tag(contentMode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(Text("desktop.contentMode"))
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.desktopContentModePicker
            )
        }
    }

    private var currentVideoSummary: some View {
        VStack(
            alignment: .leading,
            spacing: MuralumeTheme.Spacing.small
        ) {
            Text("desktop.layout.currentVideo")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)

            Text(
                verbatim: currentItem?.displayName
                    ?? localization.localized("desktop.layout.noVideo")
            )
            .font(.body.weight(.medium))
            .foregroundStyle(
                currentItem == nil
                    ? MuralumeTheme.Colors.textTertiary
                    : MuralumeTheme.Colors.textPrimary
            )
            .lineLimit(2)
        }
    }

    @ViewBuilder
    private var notices: some View {
        VStack(
            alignment: .leading,
            spacing: MuralumeTheme.Spacing.small
        ) {
            if let persistenceFailureKey {
                Label(
                    LocalizedStringKey(persistenceFailureKey),
                    systemImage: "exclamationmark.octagon.fill"
                )
                .font(.callout)
                .foregroundStyle(MuralumeTheme.Colors.error)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.desktopLayoutValidation
                )
            }

            if let validationKey {
                Label(
                    LocalizedStringKey(validationKey),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(MuralumeTheme.Colors.warning)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.desktopLayoutValidation
                )
            }

            if disconnectedAssignmentCount > 0 {
                Label {
                    Text(verbatim: disconnectedDisplaysMessage)
                } icon: {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                }
                .font(.callout)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            Spacer(minLength: MuralumeTheme.Spacing.large)

            Button("action.cancel", action: cancel)
                .buttonStyle(MuralumeSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier
                        .desktopLayoutCancelButton
                )

            Button(action: apply) {
                Text(verbatim: applyButtonTitle)
            }
            .buttonStyle(MuralumeBrandButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canApplyLayout)
            .accessibilityIdentifier(
                MuralumeAccessibilityIdentifier.desktopLayoutApplyButton
            )
        }
    }

    private var selectedDisplay: DesktopDisplayDescriptor? {
        guard let selectedDisplayID = desktopScene.selectedDisplayID else {
            return nil
        }
        return desktopScene.connectedDisplays.first {
            $0.id == selectedDisplayID
        }
    }

    private var itemsByID: [LibraryMediaItem.ID: LibraryMediaItem] {
        items.reduce(into: [:]) { result, item in
            result[item.id] = item
        }
    }

    private var validationKey: String? {
        if desktopScene.enabledDisplayCount == 0 {
            return "desktop.layout.validation.noDisplay"
        }
        guard desktopScene.scene.mode == .perDisplay else {
            return nil
        }

        let connectedIDs = Set(desktopScene.connectedDisplays.map(\.id))
        let hasMissingVideo = desktopScene.scene.assignments.contains {
            assignment in
            guard assignment.isEnabled,
                  connectedIDs.contains(assignment.displayID) else {
                return false
            }
            guard let itemID = assignment.mediaItemID else {
                return true
            }
            return itemsByID[itemID] == nil
        }
        return hasMissingVideo
            ? "desktop.layout.validation.noVideo"
            : nil
    }

    private var persistenceFailureKey: String? {
        switch desktopScene.persistenceFailure {
        case .loadFailed:
            "desktop.layout.error.load"
        case .saveFailed:
            "desktop.layout.error.save"
        case nil:
            nil
        }
    }

    private var canApplyLayout: Bool {
        validationKey == nil && desktopScene.canApply
    }

    private var disconnectedAssignmentCount: Int {
        let connectedIDs = Set(desktopScene.connectedDisplays.map(\.id))
        return desktopScene.scene.assignments.lazy.filter {
            !connectedIDs.contains($0.displayID)
        }.count
    }

    private var disconnectedDisplaysMessage: String {
        localization.localizedFormat(
            disconnectedAssignmentCount == 1
                ? "desktop.layout.disconnected.one"
                : "desktop.layout.disconnected",
            disconnectedAssignmentCount
        )
    }

    private var applyButtonTitle: String {
        let count = desktopScene.enabledDisplayCount
        return localization.localizedFormat(
            count == 1
                ? "desktop.layout.apply.one"
                : "desktop.layout.apply",
            count
        )
    }

    private func enabledBinding(
        for displayID: DesktopDisplayID
    ) -> Binding<Bool> {
        Binding(
            get: {
                desktopScene.scene.assignment(for: displayID)?
                    .isEnabled == true
            },
            set: { isEnabled in
                desktopScene.setEnabled(isEnabled, for: displayID)
            }
        )
    }

    private func contentModeBinding(
        for displayID: DesktopDisplayID
    ) -> Binding<DesktopVideoContentMode> {
        Binding(
            get: {
                if desktopScene.scene.mode == .synchronized {
                    return desktopScene.scene.defaultContentMode
                }
                return desktopScene.scene.assignment(for: displayID)?
                    .contentMode ?? desktopScene.scene.defaultContentMode
            },
            set: { contentMode in
                if desktopScene.scene.mode == .synchronized {
                    desktopScene.setDefaultContentMode(contentMode)
                } else {
                    desktopScene.setContentMode(
                        contentMode,
                        for: displayID
                    )
                }
            }
        )
    }
}
