import SwiftUI

private enum PlaybackQueueSidebarPolicy {
    static let upNextPageSize = 40
}

private enum PlaybackQueueSection: String, Hashable {
    case nowPlaying
    case upNext
}

private enum PlaybackQueueScrollTarget: Hashable {
    case nowPlaying
}

private struct PlaybackQueueEntry: Identifiable {
    struct ID: Hashable {
        let section: PlaybackQueueSection
        let occurrence: Int
        let itemID: LibraryMediaItem.ID
    }

    let id: ID
    let item: LibraryMediaItem
}

struct PlaybackQueueSidebarContent: View {
    @ObservedObject var library: MediaLibraryCoordinator
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let playbackState: LibraryMediaRowPlaybackState
    let focusRequest: UInt64
    let revealMediaInFinder: (URL) -> Void
    let showVideoInformation: (LibraryMediaItem) -> Void
    let addCurrentTemporaryToLibrary: () -> Void
    let play: (LibraryMediaItem) -> Void
    @State private var visibleUpNextCount =
        PlaybackQueueSidebarPolicy.upNextPageSize

    var body: some View {
        Group {
            if library.currentItem == nil {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(
                            alignment: .leading,
                            spacing: MuralumeTheme.Spacing.small
                        ) {
                            if let currentItem = library.currentItem {
                                queueRow(
                                    PlaybackQueueEntry(
                                        id: .init(
                                            section: .nowPlaying,
                                            occurrence: 0,
                                            itemID: currentItem.id
                                        ),
                                        item: currentItem
                                    )
                                )
                                .id(PlaybackQueueScrollTarget.nowPlaying)
                            }

                            if !upNextEntries.isEmpty {
                                sectionHeader(
                                    "queue.upNext",
                                    accessibilityIdentifier:
                                        MuralumeAccessibilityIdentifier
                                            .upNextSection
                                )
                                .padding(
                                    .top,
                                    MuralumeTheme.Spacing.xSmall
                                )

                                ForEach(upNextEntries) { entry in
                                    queueRow(entry)
                                }
                            }

                            if hasMoreUpNextItems {
                                Button("queue.showMore") {
                                    visibleUpNextCount +=
                                        PlaybackQueueSidebarPolicy
                                            .upNextPageSize
                                }
                                .buttonStyle(.borderless)
                                .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .padding(
                            .vertical,
                            MuralumeTheme.Size.playlistContentInset
                        )
                    }
                    .scrollIndicators(.visible)
                    .task(id: focusRequest) {
                        visibleUpNextCount =
                            PlaybackQueueSidebarPolicy.upNextPageSize
                        guard library.currentItem != nil else {
                            return
                        }
                        await Task.yield()
                        guard !Task.isCancelled else {
                            return
                        }
                        proxy.scrollTo(
                            PlaybackQueueScrollTarget.nowPlaying,
                            anchor: .center
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MuralumeAccessibilityIdentifier.playbackQueue
        )
    }

    private var emptyState: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            Spacer(minLength: MuralumeTheme.Spacing.large)
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                .accessibilityHidden(true)
            Text("queue.empty")
                .font(.body.weight(.semibold))
            Text("queue.empty.detail")
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: MuralumeTheme.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(
        _ title: LocalizedStringKey,
        accessibilityIdentifier: String
    ) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func queueRow(_ entry: PlaybackQueueEntry) -> some View {
        PlaybackQueueRow(
            item: entry.item,
            isCurrent: library.currentItemID == entry.item.id,
            playbackState: playbackState,
            isTemporary: library.temporaryItemIDs.contains(entry.item.id),
            mediaThumbnailProvider: mediaThumbnailProvider,
            play: {
                play(entry.item)
            },
            addToLibrary: addCurrentTemporaryToLibrary,
            revealInFinder: {
                revealMediaInFinder(entry.item.url)
            },
            showInformation: {
                showVideoInformation(entry.item)
            }
        )
    }

    private var upNextEntries: [PlaybackQueueEntry] {
        let items = library.upNextItems(limit: visibleUpNextCount)
        var occurrenceCounts: [LibraryMediaItem.ID: Int] = [:]
        return items.map { item in
            let occurrence = occurrenceCounts[item.id, default: 0]
            occurrenceCounts[item.id] = occurrence + 1
            return PlaybackQueueEntry(
                id: .init(
                    section: .upNext,
                    occurrence: occurrence,
                    itemID: item.id
                ),
                item: item
            )
        }
    }

    private var hasMoreUpNextItems: Bool {
        library.upNextItemCount > visibleUpNextCount
    }
}

private struct PlaybackQueueRow: View {
    @EnvironmentObject private var localization: AppLocalizationController

    let item: LibraryMediaItem
    let isCurrent: Bool
    let playbackState: LibraryMediaRowPlaybackState
    let isTemporary: Bool
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let play: () -> Void
    let addToLibrary: () -> Void
    let revealInFinder: () -> Void
    let showInformation: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                LibraryMediaThumbnail(
                    item: item,
                    isCurrent: isCurrent,
                    provider: mediaThumbnailProvider
                )

                VStack(
                    alignment: .leading,
                    spacing: MuralumeTheme.Spacing.xSmall
                ) {
                    Text(item.displayName)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: MuralumeTheme.Spacing.xSmall) {
                        Text(item.rootName)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if isTemporary {
                            Text("queue.temporary")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, MuralumeTheme.Spacing.small)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        MuralumeTheme.Colors.controlHover
                                    )
                                )
                                .accessibilityIdentifier(
                                    MuralumeAccessibilityIdentifier
                                        .temporaryQueueItemBadge
                                )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                }

                Spacer(minLength: MuralumeTheme.Spacing.small)

                if isCurrent {
                    currentStateIndicator
                        .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                }
            }
            .padding(MuralumeTheme.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isCurrent, isTemporary {
                Button(action: addToLibrary) {
                    Label("queue.addToLibrary", systemImage: "plus")
                }
            }
            Button(action: showInformation) {
                Label("videoInfo.menu", systemImage: "info.circle")
            }
            Button(action: revealInFinder) {
                Label("library.item.revealInFinder", systemImage: "folder")
            }
        }
        .accessibilityLabel(Text(verbatim: item.displayName))
        .accessibilityValue(Text(verbatim: accessibilityValue))
    }

    private var accessibilityValue: String {
        let stateKey = if isCurrent {
            playbackState.accessibilityKey
        } else {
            "queue.item.play"
        }
        let state = localization.localized(stateKey)
        guard isTemporary else {
            return state
        }
        return localization.localizedFormat(
            "queue.item.accessibility.temporary",
            state
        )
    }

    @ViewBuilder
    private var currentStateIndicator: some View {
        if playbackState == .loading {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(
                systemName: playbackState == .playing
                    ? "waveform"
                    : "pause.fill"
            )
        }
    }
}
