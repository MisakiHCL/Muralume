import SwiftUI

struct LibrarySidebar: View {
    @ObservedObject var library: MediaLibraryCoordinator
    @ObservedObject var playlists: CustomPlaylistController
    @ObservedObject var navigation: LibrarySidebarController
    let playback: PlaybackCoordinator
    let mediaThumbnailProvider: any MediaThumbnailProviding
    let isEditing: Bool
    let setEditing: (Bool) -> Void
    let addMedia: () -> Void
    let retryUnavailableSourceAccess: () -> Void
    let reauthorizeMediaSources: () -> Void
    let reauthorizeMediaSource: (UnavailableMediaSource) -> Void
    let removeUnavailableMediaSource: (UnavailableMediaSource) -> Void
    let canRestoreDynamicDesktop: Bool
    let addTemporaryItemsToLibrary: () -> Void
    let restoreDynamicDesktop: () -> Void
    let playLibraryItem: (LibraryMediaItem) -> Void
    let playCustomPlaylistItem:
        (LibraryMediaItem, CustomPlaylist.ID) -> Void
    let addVideosToPlaylist: (CustomPlaylist.ID) -> Void
    let addLibraryItemToPlaylist:
        (LibraryMediaItem, CustomPlaylist.ID) -> Void
    let revealMediaInFinder: (URL) -> Void
    let showVideoInformation: (LibraryMediaItem) -> Void
    let dismiss: () -> Void
    @Binding var playlistNameEditor: PlaylistNameEditorRequest?
    var reauthorizePlaylistEntry: ((CustomPlaylist.ID, CustomPlaylistEntry.ID) -> Void)? = nil
    @EnvironmentObject private var localization: AppLocalizationController

    var body: some View {
        Group {
            switch navigation.destination {
            case .mediaLibrary, .playQueue:
                LibraryQueueSidebar(
                    library: library,
                    playback: playback,
                    mediaThumbnailProvider: mediaThumbnailProvider,
                    sidebarSection: legacySection,
                    searchQuery: searchQuery,
                    browserLayout: $navigation.mediaBrowserLayout,
                    playbackQueueFocusRequest:
                        navigation.playbackQueueFocusRequest,
                    searchFocusRequest: navigation.searchFocusRequest,
                    consumeSearchFocusRequest:
                        navigation.consumeSearchFocusRequest,
                    isEditing: isEditing,
                    setEditing: setEditing,
                    addMedia: addMedia,
                    retryUnavailableSourceAccess:
                        retryUnavailableSourceAccess,
                    reauthorizeMediaSources: reauthorizeMediaSources,
                    reauthorizeMediaSource: reauthorizeMediaSource,
                    removeUnavailableMediaSource:
                        removeUnavailableMediaSource,
                    canRestoreDynamicDesktop: canRestoreDynamicDesktop,
                    addTemporaryItemsToLibrary:
                        addTemporaryItemsToLibrary,
                    restoreDynamicDesktop: restoreDynamicDesktop,
                    playLibraryItem: playLibraryItem,
                    customPlaylists: playlists.playlists,
                    customPlaylistsRevision: playlists.collectionRevision,
                    showPlaylists: {
                        navigation.selectDestination(.playlists)
                    },
                    addLibraryItemToPlaylist:
                        addLibraryItemToPlaylist,
                    addLibraryItemsToPlaylist: { items, playlistID in
                        _ = try playlists.add(items: items, to: playlistID)
                    },
                    createPlaylistWithItems: { items, complete in
                        playlistNameEditor = .createWithItems(PlaylistCreationRequest(
                            input: CustomPlaylistCreationInput(items: items),
                            complete: complete
                        ))
                    },
                    revealMediaInFinder: revealMediaInFinder,
                    showVideoInformation: showVideoInformation,
                    dismiss: dismiss
                )
            case .playlists, .playlist:
                CustomPlaylistSidebarContent(
                    library: library,
                    playlists: playlists,
                    navigation: navigation,
                    playback: playback,
                    mediaThumbnailProvider: mediaThumbnailProvider,
                    playCustomPlaylistItem: playCustomPlaylistItem,
                    addVideosToPlaylist: addVideosToPlaylist,
                    revealMediaInFinder: revealMediaInFinder,
                    showVideoInformation: showVideoInformation,
                    dismiss: dismiss,
                    nameEditor: $playlistNameEditor,
                    reauthorizePlaylistEntry: reauthorizePlaylistEntry
                )
            }
        }
        .alert("playlists.import.failed.title", isPresented: Binding(
            get: { playlists.videoImportFailure != nil },
            set: { if !$0 { playlists.dismissVideoImportFailure() } }
        )) {
            Button("action.ok") { playlists.dismissVideoImportFailure() }
        } message: {
            Text(verbatim: videoImportFailureMessage)
        }
    }

    private var videoImportFailureMessage: String {
        switch playlists.videoImportFailure {
        case .selectionLimitReached:
            localization.localizedFormat("playlists.import.limit", MediaImportPolicy.maximumTopLevelSourceCount)
        case .playlistUnavailable:
            localization.localized("playlists.error")
        case .playlistFull:
            localization.localized("playlists.addSelected.failed")
        case .unavailable, nil:
            localization.localized("playlists.authorization.failed")
        }
    }

    private var legacySection: Binding<LibrarySidebarSection> {
        Binding(
            get: {
                navigation.destination == .playQueue
                    ? .playQueue
                    : .mediaLibrary
            },
            set: { section in
                navigation.selectDestination(
                    section == .playQueue ? .playQueue : .mediaLibrary
                )
            }
        )
    }

    private var searchQuery: Binding<String> {
        Binding(
            get: { navigation.query },
            set: { query in
                navigation.updateQuery(query)
            }
        )
    }
}
