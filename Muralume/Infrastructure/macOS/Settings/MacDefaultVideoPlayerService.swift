import AppKit
import UniformTypeIdentifiers

@MainActor
protocol DefaultApplicationWorkspaceClient: AnyObject {
    func defaultApplicationURL(for contentType: UTType) -> URL?
    func setDefaultApplication(
        _ applicationURL: URL,
        for contentType: UTType
    ) async throws
}

@MainActor
final class NSWorkspaceDefaultApplicationClient:
    DefaultApplicationWorkspaceClient
{
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func defaultApplicationURL(for contentType: UTType) -> URL? {
        workspace.urlForApplication(toOpen: contentType)
    }

    func setDefaultApplication(
        _ applicationURL: URL,
        for contentType: UTType
    ) async throws {
        try await workspace.setDefaultApplication(
            at: applicationURL,
            toOpen: contentType
        )
    }
}

@MainActor
final class MacDefaultVideoPlayerService: DefaultVideoPlayerServicing {
    private static let m4vContentType =
        UTType(DefaultVideoContentType.m4v.rawValue)
        ?? UTType(importedAs: DefaultVideoContentType.m4v.rawValue)

    private static let supportedContentTypes: [UTType] = [
        .mpeg4Movie,
        .quickTimeMovie,
        m4vContentType,
    ]

    private let workspace: any DefaultApplicationWorkspaceClient
    private let applicationURL: URL

    init(
        workspace: any DefaultApplicationWorkspaceClient =
            NSWorkspaceDefaultApplicationClient(),
        applicationURL: URL = Bundle.main.bundleURL
    ) {
        self.workspace = workspace
        self.applicationURL = applicationURL
    }

    var status: DefaultVideoPlayerStatus {
        let matchingTypeCount = Self.supportedContentTypes.filter {
            currentApplicationIsDefault(for: $0)
        }.count

        switch matchingTypeCount {
        case 0:
            return .none
        case Self.supportedContentTypes.count:
            return .all
        default:
            return .partial
        }
    }

    func setAsDefault() async throws {
        for contentType in Self.supportedContentTypes {
            try Task.checkCancellation()

            if currentApplicationIsDefault(for: contentType) {
                continue
            }

            try await workspace.setDefaultApplication(
                applicationURL,
                for: contentType
            )
        }
    }

    private func currentApplicationIsDefault(
        for contentType: UTType
    ) -> Bool {
        guard let currentDefaultURL =
            workspace.defaultApplicationURL(for: contentType) else {
            return false
        }
        return Self.urlsReferToSameApplication(
            currentDefaultURL,
            applicationURL
        )
    }

    private static func urlsReferToSameApplication(
        _ lhs: URL,
        _ rhs: URL
    ) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
