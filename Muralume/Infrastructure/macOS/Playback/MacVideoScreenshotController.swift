import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct VideoScreenshotRequest: Equatable, Sendable {
    let source: ResolvedMediaSource
    let time: TimeInterval
}

protocol VideoScreenshotGenerating: Sendable {
    func jpegData(for request: VideoScreenshotRequest) async throws -> Data
}

protocol VideoScreenshotWriting: Sendable {
    @discardableResult
    func write(_ data: Data, to destinationURL: URL) async throws -> VideoScreenshotRecord
    func write(
        _ data: Data, named filename: String, in directory: URL,
        customFolder: VideoScreenshotFolder?
    ) async throws -> AutomaticVideoScreenshotWrite
}

struct AutomaticVideoScreenshotWrite: Sendable {
    let record: VideoScreenshotRecord
    var refreshedFolder: VideoScreenshotFolder? = nil
}

private enum VideoScreenshotFolderError: Error {
    case accessUnavailable
    case filenameUnavailable
}

private final class SavedVideoScreenshotAccess: Sendable {
    let url: URL
    private let scope: URL?

    init(url: URL, scope: URL?) {
        self.url = url
        self.scope = scope
    }

    deinit {
        scope?.stopAccessingSecurityScopedResource()
    }
}

private actor SavedVideoScreenshotResolver {
    func resolve(_ record: VideoScreenshotRecord) throws -> SavedVideoScreenshotAccess {
        try Task.checkCancellation()
        let bookmark: Data
        let isFolder: Bool
        switch record.access {
        case .direct:
            return SavedVideoScreenshotAccess(url: record.url, scope: nil)
        case let .fileBookmark(data):
            bookmark = data
            isFolder = false
        case let .folderBookmark(data):
            bookmark = data
            isFolder = true
        }
        var isStale = false
        let scope = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard scope.startAccessingSecurityScopedResource() else {
            throw VideoScreenshotFolderError.accessUnavailable
        }
        let file = isFolder
            ? scope.appendingPathComponent(record.url.lastPathComponent, isDirectory: false)
            : scope
        return SavedVideoScreenshotAccess(url: file, scope: scope)
    }
}

/// Serializes screenshot writes away from the UI executor. The URL granted
/// by the save panel or folder bookmark stays scoped for the complete write.
actor FileVideoScreenshotWriter: VideoScreenshotWriting {
    @discardableResult
    func write(_ data: Data, to destinationURL: URL) throws -> VideoScreenshotRecord {
        try Task.checkCancellation()
        let access = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if access { destinationURL.stopAccessingSecurityScopedResource() }
        }
        try data.write(to: destinationURL, options: .atomic)
        let bookmark = try? destinationURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let fileAccess: VideoScreenshotRecord.Access = if let bookmark,
            bookmark.count <= VideoScreenshotFolder.maximumBookmarkBytes {
            .fileBookmark(bookmark)
        } else {
            .direct
        }
        return VideoScreenshotRecord(url: destinationURL, access: fileAccess)
    }

    func write(
        _ data: Data, named filename: String, in directory: URL,
        customFolder: VideoScreenshotFolder?
    ) throws -> AutomaticVideoScreenshotWrite {
        try Task.checkCancellation()
        guard let customFolder else {
            let destination = try writeWithoutReplacing(data, named: filename, in: directory)
            return AutomaticVideoScreenshotWrite(record: VideoScreenshotRecord(url: destination))
        }

        var isStale = false
        let scopedDirectory = try URL(
            resolvingBookmarkData: customFolder.bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard scopedDirectory.startAccessingSecurityScopedResource() else {
            throw VideoScreenshotFolderError.accessUnavailable
        }
        defer { scopedDirectory.stopAccessingSecurityScopedResource() }

        let destination = try writeWithoutReplacing(data, named: filename, in: scopedDirectory)
        let refreshedFolder = if isStale || scopedDirectory.path != customFolder.path {
            try? Self.makeBookmark(for: scopedDirectory)
        } else {
            nil as VideoScreenshotFolder?
        }
        return AutomaticVideoScreenshotWrite(
            record: VideoScreenshotRecord(
                url: destination, access: .folderBookmark(refreshedFolder?.bookmark ?? customFolder.bookmark)
            ),
            refreshedFolder: refreshedFolder
        )
    }

    func bookmarkFolder(_ url: URL) throws -> VideoScreenshotFolder {
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try Self.makeBookmark(for: url)
    }

    private static func makeBookmark(for url: URL) throws -> VideoScreenshotFolder {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let folder = VideoScreenshotFolder(
            path: url.path, bookmark: bookmark, displayName: FileManager.default.displayName(atPath: url.path)
        )
        guard folder.isValid else { throw VideoScreenshotFolderError.accessUnavailable }
        return folder
    }

    private func writeWithoutReplacing(
        _ data: Data, named filename: String, in directory: URL
    ) throws -> URL {
        let extensionless = (filename as NSString).deletingPathExtension
        let pathExtension = (filename as NSString).pathExtension
        for attempt in 0..<VideoScreenshotPolicy.maximumFilenameAttempts {
            try Task.checkCancellation()
            let name = attempt == 0 ? filename : "\(extensionless)-\(attempt + 1).\(pathExtension)"
            let destination = directory.appendingPathComponent(name, isDirectory: false)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return destination
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw VideoScreenshotFolderError.filenameUnavailable
    }
}

enum VideoScreenshotGenerationError: Error, Equatable {
    case frameUnavailable
    case encodingFailed
}

private enum VideoScreenshotPolicy {
    static let maximumPixelDimension: CGFloat = 8_192
    static let fallbackFrameRate: Float = 30
    static let timeScale: CMTimeScale = 600
    static let maximumBaseNameLength = 96
    static let maximumBaseNameBytes = 192
    static let maximumFilenameAttempts = 100
    static let jpegCompressionQuality = 0.9
}

actor AVAssetVideoScreenshotGenerator: VideoScreenshotGenerating {
    func jpegData(for request: VideoScreenshotRequest) async throws -> Data {
        let sourceLease = try MediaPlaybackURLLease(
            sourceURL: request.source.url, accessLease: request.source.accessLease
        )
        defer { sourceLease.invalidate() }
        let asset = AVURLAsset(url: sourceLease.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw VideoScreenshotGenerationError.frameUnavailable
        }

        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        try Task.checkCancellation()

        let effectiveFrameRate = nominalFrameRate > 0
            ? nominalFrameRate
            : VideoScreenshotPolicy.fallbackFrameRate
        let frameTolerance = CMTime(
            seconds: 1 / Double(effectiveFrameRate),
            preferredTimescale: VideoScreenshotPolicy.timeScale
        )

        let requestedTime = CMTime(
            seconds: max(request.time, 0),
            preferredTimescale: VideoScreenshotPolicy.timeScale
        )
        let cancellationBox = VideoScreenshotGeneratorCancellationBox(
            asset: asset, frameTolerance: frameTolerance
        )
        let image: CGImage
        do {
            image = try await withTaskCancellationHandler {
                try await cancellationBox.image(at: requestedTime)
            } onCancel: {
                cancellationBox.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VideoScreenshotGenerationError.frameUnavailable
        }
        try Task.checkCancellation()

        let encodedData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encodedData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw VideoScreenshotGenerationError.encodingFailed
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality:
                VideoScreenshotPolicy.jpegCompressionQuality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw VideoScreenshotGenerationError.encodingFailed
        }
        return encodedData as Data
    }
}

private final class VideoScreenshotGeneratorCancellationBox:
    @unchecked Sendable
{
    private let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var isCancelled = false

    init(asset: AVAsset, frameTolerance: CMTime) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        generator.maximumSize = CGSize(
            width: VideoScreenshotPolicy.maximumPixelDimension,
            height: VideoScreenshotPolicy.maximumPixelDimension
        )
        generator.requestedTimeToleranceBefore = frameTolerance
        generator.requestedTimeToleranceAfter = frameTolerance
        self.generator = generator
    }

    func image(at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                guard !isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                    _, image, _, result, error in
                    if result == .succeeded, let image {
                        continuation.resume(returning: image)
                    } else if result == .cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error
                            ?? VideoScreenshotGenerationError.frameUnavailable)
                    }
                }
            }
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            generator.cancelAllCGImageGeneration()
        }
    }
}

enum VideoScreenshotFilenameBuilder {
    static func filename(
        source: ResolvedMediaSource,
        time: TimeInterval
    ) -> String {
        let displayName = (source.displayName as NSString)
            .deletingPathExtension
        let sanitizedName = sanitizedBaseName(displayName)
        let totalSeconds = Int(max(time, 0).rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60
        let timestamp = String(
            format: "%02d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            hours,
            minutes,
            seconds
        )
        return "\(sanitizedName)-\(timestamp).jpg"
    }

    private static func sanitizedBaseName(_ value: String) -> String {
        let invalidCharacters = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/:")
        )
        let sanitized = value.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? "-" : String(scalar)
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = ""
        var bytes = 0
        for character in sanitized.prefix(VideoScreenshotPolicy.maximumBaseNameLength) {
            bytes += String(character).utf8.count
            guard bytes <= VideoScreenshotPolicy.maximumBaseNameBytes else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? "Muralume" : bounded
    }
}

@MainActor
private final class MacVideoScreenshotFolderPicker: VideoScreenshotFolderSelecting {
    private let localization: AppLocalizationController
    private let writer = FileVideoScreenshotWriter()

    init(localization: AppLocalizationController) {
        self.localization = localization
    }

    func chooseFolder(startingAt directory: URL?) async throws -> VideoScreenshotFolder? {
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = localization.localized("screenshot.folder.title")
        panel.prompt = localization.localized("screenshot.folder.select")

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        // AppKit already begins access for the URL returned by its panel.
        defer { url.stopAccessingSecurityScopedResource() }
        return try await writer.bookmarkFolder(url)
    }
}

@MainActor
final class MacVideoScreenshotController: VideoScreenshotControlling {
    let folder: VideoScreenshotFolderController
    private(set) lazy var history = VideoScreenshotHistory { [weak self] record, action in
        self?.performHistoryAction(action, on: record)
    }

    private let localization: AppLocalizationController
    private let generator: any VideoScreenshotGenerating
    private let writer: any VideoScreenshotWriting
    private let historyResolver = SavedVideoScreenshotResolver()
    private var captureTask: Task<Void, Never>?
    private var historyActionTask: Task<Void, Never>?
    private var captureGeneration: UInt64 = 0
    private var activeSavePanel: NSSavePanel?

    init(
        localization: AppLocalizationController,
        generator: any VideoScreenshotGenerating =
            AVAssetVideoScreenshotGenerator(),
        writer: any VideoScreenshotWriting = FileVideoScreenshotWriter()
    ) {
        self.localization = localization
        self.generator = generator
        self.writer = writer
        folder = VideoScreenshotFolderController(
            selector: MacVideoScreenshotFolderPicker(localization: localization)
        )
    }

    deinit {
        captureTask?.cancel()
        historyActionTask?.cancel()
    }

    func capture(
        source: ResolvedMediaSource,
        at time: TimeInterval,
        destination: VideoScreenshotSaveDestination
    ) {
        guard captureTask == nil, time.isFinite, time < Double(Int.max) else {
            return
        }

        captureGeneration &+= 1
        let generation = captureGeneration
        let request = VideoScreenshotRequest(source: source, time: time)
        let suggestedFilename = VideoScreenshotFilenameBuilder.filename(
            source: source,
            time: time
        )
        let generator = generator
        let directory = folder.directoryURL
        let customFolder = folder.customFolder

        captureTask = Task { [weak self] in
            defer { self?.finishCapture(generation: generation) }
            let jpegData: Data
            do {
                jpegData = try await generator.jpegData(for: request)
                try Task.checkCancellation()
            } catch {
                if !Task.isCancelled { self?.presentFailure() }
                return
            }
            guard let self else { return }

            do {
                let saved: VideoScreenshotRecord
                switch destination {
                case .savePanel:
                    guard let destinationURL = await selectDestination(
                        suggestedFilename: suggestedFilename, directory: directory
                    ) else { return }
                    defer { destinationURL.stopAccessingSecurityScopedResource() }
                    try Task.checkCancellation()
                    saved = try await writer.write(jpegData, to: destinationURL)
                case .defaultFolder:
                    guard let directory else { throw VideoScreenshotFolderError.accessUnavailable }
                    let result = try await writer.write(
                        jpegData, named: suggestedFilename,
                        in: directory, customFolder: customFolder
                    )
                    try Task.checkCancellation()
                    if let updatedFolder = result.refreshedFolder, let customFolder {
                        folder.refreshFolder(updatedFolder, replacing: customFolder)
                    }
                    saved = result.record
                }
                try Task.checkCancellation()
                history.record(saved)
            } catch {
                if !Task.isCancelled {
                    presentFailure(messageKey: destination == .defaultFolder
                        ? "screenshot.folder.writeError" : "screenshot.error.message")
                }
            }
        }
    }

    func cancel() {
        captureGeneration &+= 1
        captureTask?.cancel()
        captureTask = nil
        historyActionTask?.cancel()
        history.clear()
        activeSavePanel?.cancel(nil)
        activeSavePanel = nil
    }

    private func performHistoryAction(_ action: VideoScreenshotHistoryAction, on record: VideoScreenshotRecord) {
        guard historyActionTask == nil else { return }
        let resolver = historyResolver
        historyActionTask = Task { [weak self] in
            defer { self?.historyActionTask = nil }
            do {
                let access = try await resolver.resolve(record)
                try Task.checkCancellation()
                switch action {
                case .open:
                    let _: NSRunningApplication = try await NSWorkspace.shared.open(
                        access.url, configuration: NSWorkspace.OpenConfiguration()
                    )
                case .reveal:
                    NSWorkspace.shared.activateFileViewerSelecting([access.url])
                }
                withExtendedLifetime(access) {}
            } catch {
                if !Task.isCancelled {
                    self?.presentAlert(titleKey: "screenshot.history.accessError")
                }
            }
        }
    }

    private func selectDestination(
        suggestedFilename: String,
        directory: URL?
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFilename
        panel.title = localization.localized("screenshot.save.title")
        panel.message = localization.localized("screenshot.save.message")
        panel.prompt = localization.localized("screenshot.save.prompt")
        activeSavePanel = panel
        defer {
            if activeSavePanel === panel {
                activeSavePanel = nil
            }
        }

        guard let window = NSApp.keyWindow else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(
                    returning: response == .OK ? panel.url : nil
                )
            }
        }
    }

    private func presentFailure(messageKey: String = "screenshot.error.message") {
        presentAlert(titleKey: "screenshot.error.title", messageKey: messageKey)
    }

    private func presentAlert(titleKey: String, messageKey: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localization.localized(titleKey)
        if let messageKey { alert.informativeText = localization.localized(messageKey) }
        alert.addButton(
            withTitle: localization.localized("action.ok")
        )
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func finishCapture(generation: UInt64) {
        guard generation == captureGeneration else {
            return
        }
        captureTask = nil
    }
}
