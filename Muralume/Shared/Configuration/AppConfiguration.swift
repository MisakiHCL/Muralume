import CoreGraphics
import Foundation

enum AppConfiguration {
    static let mainWindowSceneID = "main-window"
    static let minimumWindowWidth: CGFloat = 880
    static let minimumWindowHeight: CGFloat = 600
    static let preferredWindowWidth: CGFloat = 1_120
    static let preferredWindowHeight: CGFloat = 720
    static let mediaThumbnailCacheCountLimit = 256
    static let mediaThumbnailCacheByteLimit = 32 * 1_024 * 1_024
    static let websiteURL = makeHTTPSURL("https://hclgame.com/muralume/")
    static let privacyPolicyURL = makeHTTPSURL(
        "https://hclgame.com/muralume/privacy"
    )
    static let sourceCodeURL = makeHTTPSURL(
        "https://github.com/MisakiHCL/Muralume"
    )

    private static func makeHTTPSURL(_ value: String) -> URL {
        guard let url = URL(string: value),
              url.scheme == "https",
              url.host != nil else {
            preconditionFailure("Invalid bundled Muralume link.")
        }
        return url
    }
}
