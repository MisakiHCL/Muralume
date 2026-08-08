import Combine
import SwiftUI

struct LibraryQueueSidebar: View {
    @ObservedObject var library: MediaLibraryCoordinator
    let playback: PlaybackCoordinator
    @EnvironmentObject private var localization: AppLocalizationController
    @State private var pendingRootRemoval: MediaLibraryRoot?
    @State private var playbackStatus: LibraryPlaybackStatus
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let isEditing: Bool
    let setEditing: (Bool) -> Void
    let addVideos: () -> Void
    let addFolders: () -> Void
    let dismiss: () -> Void

    init(
        library: MediaLibraryCoordinator,
        playback: PlaybackCoordinator,
        mediaThumbnailProvider: any MediaThumbnailProviding,
        isEditing: Bool,
        setEditing: @escaping (Bool) -> Void,
        addVideos: @escaping () -> Void,
        addFolders: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.library = library
        self.playback = playback
        self.mediaThumbnailProvider = mediaThumbnailProvider
        self.isEditing = isEditing
        self.setEditing = setEditing
        self.addVideos = addVideos
        self.addFolders = addFolders
        self.dismiss = dismiss
        _playbackStatus = State(
            initialValue: LibraryPlaybackStatus(playback: playback)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.medium) {
            header

            if isEditing {
                rootEditor
            } else {
                libraryStatusBar

                Divider()
                    .overlay(MuralumeTheme.Colors.border)

                playlistContent
            }
        }
        .padding(MuralumeTheme.Spacing.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.librarySidebar
        )
        .alert(
            LocalizedStringKey(rootRemovalTitleKey),
            isPresented: rootRemovalAlertIsPresented,
            presenting: pendingRootRemoval
        ) { root in
            Button(
                LocalizedStringKey(rootRemovalConfirmKey(for: root)),
                role: .destructive
            ) {
                let removesLastRoot = library.roots.count == 1
                pendingRootRemoval = nil
                if removesLastRoot {
                    setEditing(false)
                }
                Task {
                    await library.removeRoot(root)
                }
            }
            Button("action.cancel", role: .cancel) {
                pendingRootRemoval = nil
            }
        } message: { root in
            Text(
                verbatim: localization.localizedFormat(
                    rootRemovalMessageKey(for: root),
                    root.displayName
                )
            )
        }
        .onReceive(playbackStatusPublisher) { status in
            playbackStatus = status
        }
    }

    private var header: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Label("library.playlist", systemImage: "list.bullet")
                .font(.headline)
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.libraryTitle
                )

            Spacer(minLength: MuralumeTheme.Spacing.small)

            if !isEditing {
                Menu {
                    Button(action: addVideos) {
                        Label("library.add.video", systemImage: "film")
                    }
                    Button(action: addFolders) {
                        Label("library.add.folder", systemImage: "folder")
                    }
                } label: {
                    headerActionLabel(
                        titleKey: "library.add",
                        systemImage: "plus"
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(
                    MuralumeToolbarButtonStyle(
                        width: MuralumeTheme.Size.playlistHeaderActionWidth
                    )
                )
                .help(Text("library.add"))
                .accessibilityLabel(Text("library.add"))
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.addMediaButton
                )
            }

            if !library.roots.isEmpty {
                Button {
                    setEditing(!isEditing)
                } label: {
                    headerActionLabel(
                        titleKey: isEditing
                            ? "library.done"
                            : "library.edit",
                        systemImage: isEditing
                            ? "checkmark"
                            : "pencil"
                    )
                }
                .buttonStyle(
                    MuralumeToolbarButtonStyle(
                        kind: isEditing ? .selected : .standard,
                        width: MuralumeTheme.Size.playlistHeaderActionWidth
                    )
                )
                .help(
                    Text(
                        LocalizedStringKey(
                            isEditing ? "library.done" : "library.edit"
                        )
                    )
                )
                .accessibilityLabel(
                    Text(
                        LocalizedStringKey(
                            isEditing ? "library.done" : "library.edit"
                        )
                    )
                )
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.editLibraryButton
                )
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(
                        .system(
                            size: MuralumeTheme.Size.icon,
                            weight: .semibold
                        )
                    )
            }
            .buttonStyle(MuralumeToolbarButtonStyle())
            .help(Text("library.playlist.hide"))
            .accessibilityLabel(Text("library.playlist.hide"))
        }
        .frame(
            minHeight: MuralumeTheme.Size.control,
            alignment: .center
        )
    }

    private func headerActionLabel(
        titleKey: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.xSmall) {
            Image(systemName: systemImage)
                .font(
                    .system(
                        size: MuralumeTheme.Size.icon,
                        weight: .semibold
                    )
                )

            Text(titleKey)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var refreshActionLabel: some View {
        HStack(spacing: MuralumeTheme.Spacing.xSmall) {
            Image(systemName: "arrow.clockwise")
                .font(
                    .system(
                        size: MuralumeTheme.Size.icon,
                        weight: .semibold
                    )
                )

            Text("library.refresh")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var libraryStatusBar: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            librarySummary
                .frame(maxWidth: .infinity, alignment: .leading)

            sortMenu
        }
    }

    private var rootEditor: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.small) {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                editorRefreshStatus
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    library.refresh()
                } label: {
                    refreshActionLabel
                }
                .buttonStyle(
                    MuralumeToolbarButtonStyle(
                        width: MuralumeTheme.Size
                            .playlistRefreshActionWidth
                    )
                )
                .disabled(!library.canRefresh)
                .help(Text("library.refresh"))
                .accessibilityLabel(Text("library.refresh"))
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.refreshLibraryButton
                )
            }

            Divider()
                .overlay(MuralumeTheme.Colors.border)

            ScrollView {
                LazyVStack(spacing: MuralumeTheme.Spacing.small) {
                    ForEach(library.roots) { root in
                        HStack(spacing: MuralumeTheme.Spacing.medium) {
                            Image(systemName: sourceIcon(for: root))
                                .font(.system(size: MuralumeTheme.Size.icon))
                                .foregroundStyle(
                                    MuralumeTheme.Colors.controlAccent
                                )

                            VStack(
                                alignment: .leading,
                                spacing: MuralumeTheme.Spacing.xSmall
                            ) {
                                Text(verbatim: root.displayName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(
                                        MuralumeTheme.Colors.textPrimary
                                    )
                                    .lineLimit(1)

                                Text(verbatim: root.url.path)
                                    .font(.caption)
                                    .foregroundStyle(
                                        MuralumeTheme.Colors.textTertiary
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: MuralumeTheme.Spacing.small)

                            Button {
                                pendingRootRemoval = root
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(
                                        .system(
                                            size: MuralumeTheme.Size.iconLarge,
                                            weight: .semibold
                                        )
                                    )
                                    .foregroundStyle(
                                        MuralumeTheme.Colors.error
                                    )
                                    .frame(
                                        width: MuralumeTheme.Size.control,
                                        height: MuralumeTheme.Size.control
                                    )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .help(
                                Text(
                                    LocalizedStringKey(
                                        rootRemovalLabelKey(for: root)
                                    )
                                )
                            )
                            .accessibilityLabel(
                                Text(
                                    LocalizedStringKey(
                                        rootRemovalLabelKey(for: root)
                                    )
                                )
                            )
                        }
                        .padding(MuralumeTheme.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(
                                cornerRadius: MuralumeTheme.Radius.medium,
                                style: .continuous
                            )
                            .fill(
                                MuralumeTheme.Colors.controlFill.opacity(0.52)
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: MuralumeTheme.Radius.medium,
                                    style: .continuous
                                )
                                .stroke(
                                    MuralumeTheme.Colors.border,
                                    lineWidth: 1
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, MuralumeTheme.Spacing.xSmall)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private var editorRefreshStatus: some View {
        switch library.scanState {
        case .idle:
            Text("library.summary.empty")
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .scanning:
            HStack(spacing: MuralumeTheme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .tint(MuralumeTheme.Colors.controlAccent)
                    .accessibilityHidden(true)
                Text("library.scanning")
            }
            .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .ready:
            Text(videoCountText)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .failed:
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                Text("library.scan.failed")
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            }
        }
    }

    private var rootRemovalAlertIsPresented: Binding<Bool> {
        Binding(
            get: {
                pendingRootRemoval != nil
            },
            set: { isPresented in
                if !isPresented {
                    pendingRootRemoval = nil
                }
            }
        )
    }

    @ViewBuilder
    private var librarySummary: some View {
        switch library.scanState {
        case .idle:
            Text("library.summary.empty")
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .scanning:
            HStack(spacing: MuralumeTheme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .tint(MuralumeTheme.Colors.controlAccent)
                Text("library.scanning")
            }
            .foregroundStyle(MuralumeTheme.Colors.textSecondary)
        case .ready:
            VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.xSmall) {
                HStack(
                    alignment: .firstTextBaseline,
                    spacing: MuralumeTheme.Spacing.small
                ) {
                    Text(videoCountText)
                        .foregroundStyle(
                            MuralumeTheme.Colors.textSecondary
                        )

                    if let position = library.currentPosition {
                        Text(
                            verbatim: localization.localizedFormat(
                                "queue.position",
                                position,
                                library.queueCount
                            )
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            MuralumeTheme.Colors.textTertiary
                        )
                        .accessibilityLabel(
                            Text(
                                verbatim: localization.localizedFormat(
                                    "queue.position.accessibility",
                                    position,
                                    library.queueCount
                                )
                            )
                        )
                    }
                }
                if let sourceText {
                    Text(sourceText)
                        .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .failed:
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                Text("library.scan.failed")
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                Button("library.retry") {
                    library.refresh()
                }
                .buttonStyle(.link)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(MediaLibrarySortField.allCases, id: \.self) { field in
                Button {
                    library.setSortField(field)
                } label: {
                    if library.sort.field == field {
                        Label(
                            LocalizedStringKey(field.localizedKey),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(LocalizedStringKey(field.localizedKey))
                    }
                }
            }

            Divider()

            ForEach(
                MediaLibrarySortDirection.allCases,
                id: \.self
            ) { direction in
                Button {
                    library.setSortDirection(direction)
                } label: {
                    if library.sort.direction == direction {
                        Label(
                            LocalizedStringKey(direction.localizedKey),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(
                            LocalizedStringKey(direction.localizedKey)
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(
                    .system(
                        size: MuralumeTheme.Size.icon,
                        weight: .semibold
                    )
                )
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .frame(
                    width: MuralumeTheme.Size.control,
                    height: MuralumeTheme.Size.control
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("library.sort"))
        .accessibilityLabel(Text("library.sort"))
        .accessibilityValue(Text(verbatim: sortAccessibilityValue))
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.librarySortButton
        )
    }

    @ViewBuilder
    private var playlistContent: some View {
        if library.items.isEmpty {
            LibrarySidebarEmptyState(
                scanState: library.scanState,
                hasSources: !library.roots.isEmpty
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: MuralumeTheme.Spacing.xSmall) {
                        ForEach(library.items) { item in
                            LibraryMediaRow(
                                item: item,
                                isCurrent: library.currentItemID == item.id,
                                playbackState: playbackState(for: item),
                                mediaThumbnailProvider: mediaThumbnailProvider,
                                play: {
                                    library.play(item)
                                    dismiss()
                                }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, MuralumeTheme.Spacing.xSmall)
                }
                .scrollIndicators(.visible)
                .accessibilityLabel(Text("library.playlist"))
                .task(id: library.currentItemID) {
                    guard let targetID = library.currentItemID else {
                        return
                    }
                    await positionCurrentItem(targetID, using: proxy)
                }
            }
        }
    }

    @MainActor
    private func positionCurrentItem(
        _ targetID: LibraryMediaItem.ID,
        using proxy: ScrollViewProxy
    ) async {
        await Task.yield()

        guard !Task.isCancelled,
              library.currentItemID == targetID,
              library.items.contains(where: { $0.id == targetID }) else {
            return
        }
        proxy.scrollTo(targetID, anchor: .center)
    }

    private func playbackState(
        for item: LibraryMediaItem
    ) -> LibraryMediaRowPlaybackState {
        if library.unavailableItemIDs.contains(item.id) {
            return .unavailable
        }
        guard library.currentItemID == item.id else {
            return .available
        }

        return playbackStatus.rowState
    }

    private var playbackStatusPublisher:
        AnyPublisher<LibraryPlaybackStatus, Never> {
        Publishers.CombineLatest3(
            playback.$readiness,
            playback.$isPlaybackRequested,
            playback.$hasPlayableMedia
        )
        .map { readiness, isPlaybackRequested, hasPlayableMedia in
            LibraryPlaybackStatus(
                readiness: readiness,
                isPlaybackRequested: isPlaybackRequested,
                hasPlayableMedia: hasPlayableMedia
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    private var videoCountText: String {
        localization.localizedFormat(
            "library.video.count",
            library.items.count
        )
    }

    private func sourceIcon(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "film.fill"
        case .folder:
            "folder.fill"
        }
    }

    private func rootRemovalLabelKey(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "library.video.remove"
        case .folder:
            "library.folder.remove"
        }
    }

    private var rootRemovalTitleKey: String {
        guard let pendingRootRemoval else {
            return "library.source.remove.title"
        }
        switch pendingRootRemoval.kind {
        case .file:
            return "library.video.remove.title"
        case .folder:
            return "library.folder.remove.title"
        }
    }

    private func rootRemovalMessageKey(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "library.video.remove.message"
        case .folder:
            "library.folder.remove.message"
        }
    }

    private func rootRemovalConfirmKey(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "library.video.remove.confirm"
        case .folder:
            "library.folder.remove.confirm"
        }
    }

    private var sourceText: String? {
        guard !library.roots.isEmpty else {
            return nil
        }
        if library.roots.count == 1 {
            return library.roots[0].displayName
        }
        return localization.localizedFormat(
            "library.source.count",
            library.roots.count
        )
    }

    private var sortAccessibilityValue: String {
        let field = localization.localized(
            library.sort.field.localizedKey
        )
        let direction = localization.localized(
            library.sort.direction.localizedKey
        )
        return "\(field), \(direction)"
    }
}

private struct LibraryPlaybackStatus: Equatable {
    let rowState: LibraryMediaRowPlaybackState

    @MainActor
    init(playback: PlaybackCoordinator) {
        self.init(
            readiness: playback.readiness,
            isPlaybackRequested: playback.isPlaybackRequested,
            hasPlayableMedia: playback.hasPlayableMedia
        )
    }

    init(
        readiness: PlaybackReadiness,
        isPlaybackRequested: Bool,
        hasPlayableMedia: Bool
    ) {
        if hasPlayableMedia {
            rowState = isPlaybackRequested ? .playing : .paused
            return
        }

        switch readiness {
        case .loading:
            rowState = .loading
        case .ready:
            rowState = isPlaybackRequested ? .playing : .paused
        case .empty, .failed:
            rowState = .paused
        }
    }
}

private enum LibraryMediaRowPlaybackState: Equatable {
    case available
    case loading
    case playing
    case paused
    case unavailable

    var accessibilityKey: String {
        switch self {
        case .available:
            "queue.item.play"
        case .loading:
            "queue.item.loading"
        case .playing:
            "queue.item.playing"
        case .paused:
            "queue.item.paused"
        case .unavailable:
            "queue.item.unavailable"
        }
    }
}

private struct LibraryMediaRow: View {
    @EnvironmentObject private var localization: AppLocalizationController

    let item: LibraryMediaItem
    let isCurrent: Bool
    let playbackState: LibraryMediaRowPlaybackState
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                currentIndicator
                LibraryMediaThumbnail(
                    item: item,
                    isCurrent: isCurrent,
                    provider: mediaThumbnailProvider
                )

                VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.xSmall) {
                    Text(item.displayName)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(locationText)
                        .font(.caption)
                        .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                        Text(verbatim: fileSizeText)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(verbatim: "·")
                            .accessibilityHidden(true)

                        Text(verbatim: creationDateText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                }

                Spacer(minLength: MuralumeTheme.Spacing.xSmall)

                ZStack {
                    switch playbackState {
                    case .unavailable:
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(MuralumeTheme.Colors.error)
                            .help(Text("library.item.unavailable"))
                    case .loading:
                        ProgressView()
                            .controlSize(.small)
                            .tint(MuralumeTheme.Colors.controlAccent)
                    case .playing:
                        Image(systemName: "waveform")
                            .foregroundStyle(
                                MuralumeTheme.Colors.controlAccent
                            )
                    case .paused:
                        Image(systemName: "play.fill")
                            .foregroundStyle(
                                MuralumeTheme.Colors.controlAccent
                            )
                    case .available:
                        Color.clear
                    }
                }
                .frame(
                    width: MuralumeTheme.Size.iconLarge,
                    height: MuralumeTheme.Size.iconLarge
                )
            }
            .padding(.vertical, MuralumeTheme.Spacing.small)
            .padding(.trailing, MuralumeTheme.Spacing.small)
            .frame(
                maxWidth: .infinity,
                minHeight: MuralumeTheme.Size.playlistRowHeight,
                alignment: .leading
            )
            .background {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .fill(
                    isCurrent
                        ? MuralumeTheme.Colors.controlHover
                        : MuralumeTheme.Colors.controlFill.opacity(0.36)
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: MuralumeTheme.Radius.medium,
                        style: .continuous
                    )
                    .stroke(
                        isCurrent
                            ? MuralumeTheme.Colors.borderStrong
                            : Color.clear,
                        lineWidth: 1
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(Text(verbatim: item.relativePath))
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityValue(
            Text(
                LocalizedStringKey(playbackState.accessibilityKey)
            )
        )
    }

    private var currentIndicator: some View {
        RoundedRectangle(
            cornerRadius: MuralumeTheme.Radius.small,
            style: .continuous
        )
        .fill(isCurrent ? MuralumeTheme.brandGradient : LinearGradient(
            colors: [.clear],
            startPoint: .top,
            endPoint: .bottom
        ))
        .frame(width: MuralumeTheme.Spacing.xSmall)
    }

    private var locationText: String {
        guard !item.relativeDirectory.isEmpty else {
            return item.rootName
        }
        return "\(item.rootName) / \(item.relativeDirectory)"
    }

    private var fileSizeText: String {
        ByteCountFormatStyle(
            style: .file,
            allowedUnits: .all,
            spellsOutZero: false,
            includesActualByteCount: false
        )
            .locale(localization.locale)
            .format(max(item.fileSize, 0))
    }

    private var creationDateText: String {
        guard let creationDate = item.creationDate else {
            return localization.localized(
                "library.item.creationDate.unavailable"
            )
        }

        return Date.FormatStyle(
            date: .numeric,
            time: .shortened,
            locale: localization.locale
        )
        .format(creationDate)
    }

    private var accessibilityLabel: String {
        let metadata: String
        if item.creationDate == nil {
            metadata = localization.localizedFormat(
                "library.item.metadata.accessibility.dateUnavailable",
                fileSizeText
            )
        } else {
            metadata = localization.localizedFormat(
                "library.item.metadata.accessibility",
                fileSizeText,
                creationDateText
            )
        }
        return "\(item.displayName), \(locationText), \(metadata)"
    }
}

private struct LibrarySidebarEmptyState: View {
    let scanState: MediaLibraryScanState
    let hasSources: Bool

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            Spacer(minLength: MuralumeTheme.Spacing.large)

            Image(
                systemName: scanState == .scanning
                    ? "magnifyingglass"
                    : "plus.rectangle.on.folder"
            )
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(MuralumeTheme.Colors.controlAccent)
            .accessibilityHidden(true)

            Text(
                LocalizedStringKey(
                    scanState == .scanning
                        ? "library.scanning"
                        : hasSources
                            ? "library.empty.title"
                            : "media.none.title"
                )
            )
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)

            if scanState != .scanning {
                Text(
                    LocalizedStringKey(
                        hasSources
                            ? "library.empty.detail"
                            : "media.none.detail"
                    )
                )
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            }

            Spacer(minLength: MuralumeTheme.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MuralumeTheme.Spacing.medium)
    }
}

private extension MediaLibrarySortField {
    var localizedKey: String {
        switch self {
        case .name:
            "library.sort.name"
        case .creationDate:
            "library.sort.creationDate"
        case .fileSize:
            "library.sort.fileSize"
        }
    }
}

private extension MediaLibrarySortDirection {
    var localizedKey: String {
        switch self {
        case .ascending:
            "library.sort.ascending"
        case .descending:
            "library.sort.descending"
        }
    }
}
