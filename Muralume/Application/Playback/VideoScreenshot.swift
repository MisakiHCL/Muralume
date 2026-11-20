import Combine
import Foundation

enum VideoScreenshotSaveDestination: Equatable {
    case savePanel
    case defaultFolder
}

struct VideoScreenshotFolder: Codable, Equatable, Sendable {
    static let maximumBookmarkBytes = 64 * 1_024

    let path: String
    let bookmark: Data
    var displayName: String? = nil

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var isValid: Bool {
        path.hasPrefix("/") && path.utf8.count <= 4_096
            && !bookmark.isEmpty && bookmark.count <= Self.maximumBookmarkBytes
    }
}

@MainActor
protocol VideoScreenshotFolderSelecting {
    func chooseFolder(startingAt directory: URL?) async throws -> VideoScreenshotFolder?
}

@MainActor
final class VideoScreenshotFolderController: ObservableObject {
    private static let storageKey = "settings.screenshot.folder.v1"
    private static let maximumStoredBytes = VideoScreenshotFolder.maximumBookmarkBytes * 2

    @Published private(set) var customFolder: VideoScreenshotFolder?
    @Published private(set) var isChoosingFolder = false
    @Published private(set) var selectionFailed = false

    private let selector: any VideoScreenshotFolderSelecting
    private let defaults: UserDefaults

    init(selector: any VideoScreenshotFolderSelecting, defaults: UserDefaults = .standard) {
        self.selector = selector
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           data.count <= Self.maximumStoredBytes,
           let folder = try? PropertyListDecoder().decode(VideoScreenshotFolder.self, from: data),
           folder.isValid {
            customFolder = folder
        }
    }

    var directoryURL: URL? {
        customFolder?.url ?? downloadsURL
    }

    var usesDownloadsName: Bool {
        customFolder == nil || customFolder?.url.standardizedFileURL == downloadsURL?.standardizedFileURL
    }

    private var downloadsURL: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    func chooseFolder() async {
        guard !isChoosingFolder else { return }
        isChoosingFolder = true
        selectionFailed = false
        defer { isChoosingFolder = false }
        do {
            if let folder = try await selector.chooseFolder(startingAt: directoryURL),
               !Task.isCancelled {
                selectionFailed = !save(folder)
            }
        } catch {
            selectionFailed = !Task.isCancelled
        }
    }

    func refreshFolder(_ updated: VideoScreenshotFolder, replacing old: VideoScreenshotFolder) {
        guard customFolder == old else { return }
        _ = save(updated)
    }

    private func save(_ folder: VideoScreenshotFolder) -> Bool {
        guard folder.isValid, let data = try? PropertyListEncoder().encode(folder) else {
            return false
        }
        defaults.set(data, forKey: Self.storageKey)
        customFolder = folder
        return true
    }
}

struct VideoScreenshotRecord: Identifiable, Equatable, Sendable {
    enum Access: Equatable, Sendable {
        case direct
        case fileBookmark(Data)
        case folderBookmark(Data)
    }

    let id = UUID()
    let url: URL
    var access: Access = .direct
}

enum VideoScreenshotHistoryAction {
    case open
    case reveal
}

@MainActor
final class VideoScreenshotHistory: ObservableObject {
    private static let maximumCount = 20
    @Published private(set) var records: [VideoScreenshotRecord] = []
    private let performAction: (VideoScreenshotRecord, VideoScreenshotHistoryAction) -> Void

    init(performAction: @escaping (VideoScreenshotRecord, VideoScreenshotHistoryAction) -> Void) {
        self.performAction = performAction
    }

    func record(_ saved: VideoScreenshotRecord) {
        var recent = records.filter { $0.url != saved.url }
        recent.insert(saved, at: 0)
        records = Array(recent.prefix(Self.maximumCount))
    }

    func perform(_ action: VideoScreenshotHistoryAction, on record: VideoScreenshotRecord) {
        guard records.contains(record) else { return }
        performAction(record, action)
    }

    func clear() {
        if !records.isEmpty { records.removeAll() }
    }
}

@MainActor
protocol VideoScreenshotControlling: AnyObject {
    var folder: VideoScreenshotFolderController { get }
    var history: VideoScreenshotHistory { get }

    func capture(
        source: ResolvedMediaSource,
        at time: TimeInterval,
        destination: VideoScreenshotSaveDestination
    )
    func cancel()
}
