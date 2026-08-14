import Foundation

/// Identifies the collection whose complete ordering owns the active queue.
/// `fixed` preserves an already-built queue after its source collection is no
/// longer available, without accidentally expanding it to the media library.
enum PlaybackCollection: Equatable, Sendable, Codable {
    case mediaLibrary
    case customPlaylist(CustomPlaylist.ID)
    case fixed

    private enum Kind: String, Codable {
        case mediaLibrary
        case customPlaylist
        case fixed
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case playlistID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .mediaLibrary:
            self = .mediaLibrary
        case .customPlaylist:
            let rawID = try container.decode(UUID.self, forKey: .playlistID)
            self = .customPlaylist(CustomPlaylist.ID(rawValue: rawID))
        case .fixed:
            self = .fixed
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mediaLibrary:
            try container.encode(Kind.mediaLibrary, forKey: .kind)
        case let .customPlaylist(id):
            try container.encode(Kind.customPlaylist, forKey: .kind)
            try container.encode(id.rawValue, forKey: .playlistID)
        case .fixed:
            try container.encode(Kind.fixed, forKey: .kind)
        }
    }
}
