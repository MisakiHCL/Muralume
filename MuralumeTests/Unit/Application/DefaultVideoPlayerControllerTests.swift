import UniformTypeIdentifiers
import XCTest
@testable import Muralume

@MainActor
final class DefaultVideoPlayerControllerTests: XCTestCase {
    private let applicationURL = URL(
        fileURLWithPath: "/Applications/Muralume.app",
        isDirectory: true
    )
    private let otherApplicationURL = URL(
        fileURLWithPath: "/Applications/Other Player.app",
        isDirectory: true
    )

    func testSupportedContentTypeIdentifiersAreExact() {
        XCTAssertEqual(
            SupportedVideoContentType.allCases.map(\.rawValue),
            [
                "public.mpeg-4",
                "com.apple.quicktime-movie",
                "com.apple.m4v-video",
                "public.mpeg",
                "public.mpeg-2-video",
                "public.mpeg-2-transport-stream",
                "public.3gpp",
                "public.3gpp2",
                "public.avi",
                "public.dv-movie",
            ]
        )
        XCTAssertEqual(
            UTType.mpeg4Movie.identifier,
            SupportedVideoContentType.mpeg4.rawValue
        )
        XCTAssertEqual(
            UTType.quickTimeMovie.identifier,
            SupportedVideoContentType.quickTimeMovie.rawValue
        )
        XCTAssertEqual(
            UTType.mpeg.identifier,
            SupportedVideoContentType.mpeg.rawValue
        )
        XCTAssertEqual(
            UTType.mpeg2Video.identifier,
            SupportedVideoContentType.mpeg2Video.rawValue
        )
        XCTAssertEqual(
            UTType.mpeg2TransportStream.identifier,
            SupportedVideoContentType.mpeg2TransportStream.rawValue
        )
        XCTAssertEqual(
            UTType.avi.identifier,
            SupportedVideoContentType.avi.rawValue
        )
    }

    func testApplicationDeclaresViewerDocumentTypesWithAlternateRank() throws {
        let documentTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
                as? [NSDictionary]
        )
        let documentType = try XCTUnwrap(documentTypes.first)

        XCTAssertEqual(documentTypes.count, 1)
        XCTAssertEqual(documentType["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(documentType["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(
            documentType["LSItemContentTypes"] as? [String],
            SupportedVideoContentType.allCases.map(\.rawValue)
        )
    }

    func testServiceReportsNoneWhenNoAssociationMatches() {
        let workspace = TestDefaultApplicationWorkspaceClient(
            defaultApplicationURL: otherApplicationURL
        )
        let service = makeService(workspace: workspace)

        XCTAssertEqual(service.status, .none)
    }

    func testServiceReportsPartialWhenOnlySomeAssociationsMatch() {
        let workspace = TestDefaultApplicationWorkspaceClient(
            defaultApplicationURL: otherApplicationURL
        )
        workspace.defaultApplicationURLs[
            SupportedVideoContentType.mpeg4.rawValue
        ] = applicationURL
        let service = makeService(workspace: workspace)

        XCTAssertEqual(service.status, .partial)
    }

    func testServiceReportsAllWhenEveryAssociationMatches() {
        let workspace = TestDefaultApplicationWorkspaceClient(
            defaultApplicationURL: applicationURL
        )
        let service = makeService(workspace: workspace)

        XCTAssertEqual(service.status, .all)
    }

    func testSetAsDefaultOnlyUpdatesMissingAssociations() async throws {
        let workspace = TestDefaultApplicationWorkspaceClient()
        workspace.defaultApplicationURLs[
            SupportedVideoContentType.mpeg4.rawValue
        ] = applicationURL
        workspace.defaultApplicationURLs[
            SupportedVideoContentType.quickTimeMovie.rawValue
        ] = otherApplicationURL
        let service = makeService(workspace: workspace)

        try await service.setAsDefault()

        XCTAssertEqual(
            workspace.requestedContentTypeIdentifiers,
            SupportedVideoContentType.allCases.dropFirst().map(\.rawValue)
        )
        XCTAssertEqual(service.status, .all)
    }

    func testSetAsDefaultStopsAfterFirstSystemFailure() async {
        let workspace = TestDefaultApplicationWorkspaceClient()
        workspace.defaultApplicationURLs[
            SupportedVideoContentType.mpeg4.rawValue
        ] = applicationURL
        workspace.failingContentTypeIdentifiers = [
            SupportedVideoContentType.quickTimeMovie.rawValue,
        ]
        let service = makeService(workspace: workspace)

        var didThrow = false
        do {
            try await service.setAsDefault()
        } catch {
            didThrow = true
        }

        XCTAssertTrue(didThrow)
        XCTAssertEqual(
            workspace.requestedContentTypeIdentifiers,
            [SupportedVideoContentType.quickTimeMovie.rawValue]
        )
        XCTAssertEqual(service.status, .partial)
    }

    func testControllerRefreshesAuthoritativeStatusAfterSuccess() async {
        let service = ControllableDefaultVideoPlayerService(status: .none)
        service.statusAfterSet = .all
        let controller = DefaultVideoPlayerController(service: service)

        await controller.setAsDefault()

        XCTAssertEqual(service.setAsDefaultCount, 1)
        XCTAssertEqual(controller.status, .all)
        XCTAssertTrue(controller.isDefault)
        XCTAssertNil(controller.operationFailure)
        XCTAssertFalse(controller.isUpdating)
    }

    func testControllerReportsPartialStatusAfterFailure() async {
        let service = ControllableDefaultVideoPlayerService(status: .none)
        service.statusAfterSet = .partial
        service.setAsDefaultError = TestDefaultVideoPlayerError.failed
        let controller = DefaultVideoPlayerController(service: service)

        await controller.setAsDefault()

        XCTAssertEqual(controller.status, .partial)
        XCTAssertFalse(controller.isDefault)
        XCTAssertEqual(controller.operationFailure, .setDefaultFailed)

        service.status = .all
        controller.refresh()
        XCTAssertNil(controller.operationFailure)
    }

    func testControllerUsesAllStatusWhenSystemThrowsAfterApplyingChanges()
        async {
        let service = ControllableDefaultVideoPlayerService(status: .none)
        service.statusAfterSet = .all
        service.setAsDefaultError = TestDefaultVideoPlayerError.failed
        let controller = DefaultVideoPlayerController(service: service)

        await controller.setAsDefault()

        XCTAssertEqual(service.setAsDefaultCount, 1)
        XCTAssertEqual(controller.status, .all)
        XCTAssertTrue(controller.isDefault)
        XCTAssertNil(controller.operationFailure)
        XCTAssertFalse(controller.isUpdating)
    }

    func testControllerReportsFailureWhenRequestDoesNotReachAllStatus()
        async {
        let service = ControllableDefaultVideoPlayerService(status: .none)
        service.statusAfterSet = .partial
        let controller = DefaultVideoPlayerController(service: service)

        await controller.setAsDefault()

        XCTAssertEqual(service.setAsDefaultCount, 1)
        XCTAssertEqual(controller.status, .partial)
        XCTAssertFalse(controller.isDefault)
        XCTAssertEqual(controller.operationFailure, .setDefaultFailed)
        XCTAssertFalse(controller.isUpdating)
    }

    func testControllerDoesNotWriteWhenAlreadyDefault() async {
        let service = ControllableDefaultVideoPlayerService(status: .all)
        let controller = DefaultVideoPlayerController(service: service)

        await controller.setAsDefault()

        XCTAssertEqual(service.setAsDefaultCount, 0)
        XCTAssertNil(controller.operationFailure)
    }

    private func makeService(
        workspace: TestDefaultApplicationWorkspaceClient
    ) -> MacDefaultVideoPlayerService {
        MacDefaultVideoPlayerService(
            workspace: workspace,
            applicationURL: applicationURL
        )
    }
}

private enum TestDefaultVideoPlayerError: Error {
    case failed
}

@MainActor
private final class TestDefaultApplicationWorkspaceClient:
    DefaultApplicationWorkspaceClient
{
    var defaultApplicationURLs: [String: URL]
    var failingContentTypeIdentifiers: Set<String> = []
    private(set) var requestedContentTypeIdentifiers: [String] = []

    init(defaultApplicationURL: URL? = nil) {
        if let defaultApplicationURL {
            defaultApplicationURLs = Dictionary(
                uniqueKeysWithValues: SupportedVideoContentType.allCases.map {
                    ($0.rawValue, defaultApplicationURL)
                }
            )
        } else {
            defaultApplicationURLs = [:]
        }
    }

    func defaultApplicationURL(for contentType: UTType) -> URL? {
        defaultApplicationURLs[contentType.identifier]
    }

    func setDefaultApplication(
        _ applicationURL: URL,
        for contentType: UTType
    ) async throws {
        requestedContentTypeIdentifiers.append(contentType.identifier)
        if failingContentTypeIdentifiers.contains(contentType.identifier) {
            throw TestDefaultVideoPlayerError.failed
        }
        defaultApplicationURLs[contentType.identifier] = applicationURL
    }
}

@MainActor
private final class ControllableDefaultVideoPlayerService:
    DefaultVideoPlayerServicing
{
    var status: DefaultVideoPlayerStatus
    var statusAfterSet: DefaultVideoPlayerStatus?
    var setAsDefaultError: (any Error)?
    private(set) var setAsDefaultCount = 0

    init(status: DefaultVideoPlayerStatus) {
        self.status = status
    }

    func setAsDefault() async throws {
        setAsDefaultCount += 1
        if let statusAfterSet {
            status = statusAfterSet
        }
        if let setAsDefaultError {
            throw setAsDefaultError
        }
    }
}
