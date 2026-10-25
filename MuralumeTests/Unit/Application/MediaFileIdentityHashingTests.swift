import Foundation
import XCTest
@testable import Muralume

final class MediaFileIdentityHashingTests: XCTestCase {
    func testMiddleByteDifferencesRemainWellDistributedInBothComponents() {
        let fixed = archive(0)
        let count = 128
        for varyVolume in [false, true] {
            let identities = (0..<count).map { index in
                MediaFileIdentity(
                    volumeIdentifier: varyVolume ? archive(index) : fixed,
                    fileIdentifier: varyVolume ? fixed : archive(index)
                )
            }
            XCTAssertEqual(Set(identities).count, count)
            // Hash collisions remain legal. A broad distribution threshold
            // catches deterministic archive-prefix sampling, not rare pairs.
            XCTAssertGreaterThan(Set(identities.map(\.hashValue)).count, count * 3 / 4)
        }
    }

    func testEqualNativeBridgedAndSlicedDataHaveEqualHashesAndLookups() {
        let volume = archive(7)
        let file = archive(19)
        let packedVolume = Data([0, 0]) + volume + Data([0])
        let packedFile = Data([0, 0, 0]) + file + Data([0, 0])
        let native = MediaFileIdentity(volumeIdentifier: volume, fileIdentifier: file)
        let sliced = MediaFileIdentity(
            volumeIdentifier: packedVolume[2..<(2 + volume.count)],
            fileIdentifier: packedFile[3..<(3 + file.count)]
        )
        let bridged = MediaFileIdentity(
            volumeIdentifier: Data(referencing: NSData(data: volume)),
            fileIdentifier: Data(referencing: NSData(data: file))
        )
        for equivalent in [sliced, bridged] {
            XCTAssertEqual(native, equivalent)
            XCTAssertEqual(native.hashValue, equivalent.hashValue)
            XCTAssertEqual([native: "found"][equivalent], "found")
        }
        XCTAssertTrue(native.isValid)
        XCTAssertFalse(MediaFileIdentity(volumeIdentifier: Data(), fileIdentifier: file).isValid)
        XCTAssertFalse(MediaFileIdentity(volumeIdentifier: volume, fileIdentifier: Data()).isValid)
    }

    func testCodableRetainsExistingFieldsAndLegacyPayload() throws {
        let legacy = Data(#"{"volumeIdentifier":"AQID","fileIdentifier":"BAUG"}"#.utf8)
        let decoded = try JSONDecoder().decode(MediaFileIdentity.self, from: legacy)
        XCTAssertEqual(decoded, MediaFileIdentity(
            volumeIdentifier: Data([1, 2, 3]), fileIdentifier: Data([4, 5, 6])
        ))
        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(object, ["volumeIdentifier": "AQID", "fileIdentifier": "BAUG"])
        let roundTrip = try JSONDecoder().decode(MediaFileIdentity.self, from: encoded)
        XCTAssertEqual(roundTrip, decoded)
        XCTAssertEqual(roundTrip.hashValue, decoded.hashValue)
    }

    func testComponentBoundariesParticipateInHashDistribution() {
        let bytes = Data((0..<129).map { UInt8($0) })
        let identities = (1..<128).map { boundary in
            MediaFileIdentity(
                volumeIdentifier: bytes[..<boundary],
                fileIdentifier: bytes[boundary...]
            )
        }
        XCTAssertEqual(Set(identities).count, identities.count)
        XCTAssertGreaterThan(Set(identities.map(\.hashValue)).count, identities.count * 3 / 4)
    }

    func testIdentityIndexKeepsExactPriorityRenameFallbackAndAmbiguity() {
        let firstIdentity = MediaFileIdentity(volumeIdentifier: archive(0), fileIdentifier: archive(1))
        let secondIdentity = MediaFileIdentity(volumeIdentifier: archive(0), fileIdentifier: archive(2))
        let sharedIdentity = MediaFileIdentity(volumeIdentifier: archive(0), fileIdentifier: archive(3))
        let exact = item("exact.mov", identity: firstIdentity)
        let renamed = item("renamed.mov", identity: secondIdentity)
        let hardLinkA = item("link-a.mov", identity: sharedIdentity)
        let hardLinkB = item("link-b.mov", identity: sharedIdentity)
        let index = MediaReferenceResolutionIndex(items: [exact, renamed, hardLinkA, hardLinkB])
        let exactWithDifferentIdentity = MediaReference(
            mediaItemID: exact.id, fileIdentity: secondIdentity, lastKnownDisplayName: "Synthetic"
        )
        let oldName = MediaReference(
            mediaItemID: item("old.mov", identity: secondIdentity).id,
            fileIdentity: secondIdentity, lastKnownDisplayName: "Synthetic"
        )
        let ambiguous = MediaReference(
            mediaItemID: item("missing.mov", identity: sharedIdentity).id,
            fileIdentity: sharedIdentity, lastKnownDisplayName: "Synthetic"
        )
        XCTAssertEqual(index.resolve(exactWithDifferentIdentity), exact)
        XCTAssertEqual(index.resolve(oldName), renamed)
        XCTAssertNil(index.resolve(ambiguous))
        XCTAssertEqual(index.resolveReferences([oldName, MediaReference(item: renamed)]), [nil, renamed])
    }

    private func archive(_ number: Int) -> Data {
        var result = Data(repeating: 0xA5, count: 512)
        result[253] = UInt8(truncatingIfNeeded: number)
        result[254] = UInt8(truncatingIfNeeded: number >> 8)
        return result
    }

    private func item(_ path: String, identity: MediaFileIdentity) -> LibraryMediaItem {
        let root = URL(fileURLWithPath: "/SyntheticIdentityLibrary")
        return LibraryMediaItem(
            rootURL: root, rootName: "Synthetic", url: root.appendingPathComponent(path),
            displayName: "Synthetic", relativePath: path, relativeDirectory: "",
            creationDate: nil, fileSize: 1, fileIdentity: identity
        )
    }
}
