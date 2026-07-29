import CoreGraphics

enum AppConfiguration {
    static let mainWindowSceneID = "main-window"
    static let minimumWindowWidth: CGFloat = 880
    static let minimumWindowHeight: CGFloat = 600
    static let preferredWindowWidth: CGFloat = 1_120
    static let preferredWindowHeight: CGFloat = 720
    static let settingsWindowWidth: CGFloat = 520
    static let settingsWindowHeight: CGFloat = 280
    static let mediaThumbnailCacheCountLimit = 256
    static let mediaThumbnailCacheByteLimit = 32 * 1_024 * 1_024
}
