import Foundation
import XCTest

/// Each factory call owns disposable app-side storage; reusing its application
/// wrapper preserves the same session for an intentional relaunch.
@MainActor
enum MuralumeUITestSession {
    static let environmentKey = "MURALUME_UI_TEST_SESSION_ID"
    private static let targetInfoKey = "MuralumeTargetBundleIdentifier"
    private static let expectedBundleIdentifier = "com.muralume.Muralume.uitesting"

    enum ConfigurationError: Error, LocalizedError {
        case unexpectedTarget(String?)
        case invalidSession

        nonisolated var errorDescription: String? {
            switch self {
            case let .unexpectedTarget(identifier):
                "UI tests require the isolated com.muralume.Muralume.uitesting target; "
                    + "MuralumeTargetBundleIdentifier is \(identifier ?? "missing"). "
                    + "No application was launched."
            case .invalidSession:
                "UI tests require a valid MURALUME_UI_TEST_SESSION_ID UUID. "
                    + "Create the application with MuralumeUITestSession before launching it."
            }
        }
    }

    static func makeApplication(for testClass: AnyClass) throws -> XCUIApplication {
        try validateTarget(for: testClass)
        let application = XCUIApplication()
        application.launchEnvironment[environmentKey] = UUID().uuidString
        return application
    }

    static func launch(_ application: XCUIApplication, for testClass: AnyClass) throws {
        try validateTarget(for: testClass)
        guard let sessionID = application.launchEnvironment[environmentKey],
              UUID(uuidString: sessionID)?.uuidString == sessionID.uppercased() else {
            throw ConfigurationError.invalidSession
        }
        application.launch()
    }

    private static func validateTarget(for testClass: AnyClass) throws {
        let identifier = Bundle(for: testClass)
            .object(forInfoDictionaryKey: targetInfoKey) as? String
        guard identifier == expectedBundleIdentifier else {
            throw ConfigurationError.unexpectedTarget(identifier)
        }
    }
}
