import XCTest
@testable import Muralume

final class TemporaryPlaybackInputDeduplicatorTests: XCTestCase {
    func testMixedMemoryAndDiskOperationsMatchSwiftSetSemantics() throws {
        let directory = try makeScratchParent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deduplicator = TemporaryPlaybackInputDeduplicator(temporaryDirectoryURL: directory)
        var canonical: Set<String> = []
        var state: UInt64 = 0xA53C_917D
        for index in 0..<20_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let number = state % 2_000
            let suffix = index.isMultiple(of: 2) ? "Caf\u{e9}" : "Cafe\u{301}"
            let key = "/\(number)/\(suffix)\0.mp4"
            XCTAssertEqual(
                try deduplicator.insertCanonicalPath(key),
                canonical.insert(key).inserted
            )
        }
        XCTAssertNotNil(deduplicator.scratchDirectoryURL)
        XCTAssertLessThanOrEqual(
            deduplicator.maximumResidentKeyCount,
            TemporaryPlaybackInputDeduplicator.Budget.maximumResidentKeyCount
        )
        XCTAssertLessThanOrEqual(
            deduplicator.maximumResidentUTF8Bytes,
            TemporaryPlaybackInputDeduplicator.Budget.maximumResidentUTF8Bytes
        )
    }

    func testSpillRetainsStringEqualityAndReleasesAllScratchFiles() throws {
        let directory = try makeScratchParent()
        defer { try? FileManager.default.removeItem(at: directory) }
        var deduplicator: TemporaryPlaybackInputDeduplicator? = .init(
            temporaryDirectoryURL: directory
        )
        XCTAssertTrue(try deduplicator!.insertCanonicalPath("/Caf\u{e9}.mp4"))
        XCTAssertFalse(try deduplicator!.insertCanonicalPath("/Cafe\u{301}.mp4"))
        for index in 1..<TemporaryPlaybackInputDeduplicator.Budget.maximumResidentKeyCount {
            XCTAssertTrue(try deduplicator!.insertCanonicalPath("/\(index).mp4"))
        }
        XCTAssertNil(deduplicator!.scratchDirectoryURL)
        XCTAssertTrue(try deduplicator!.insertCanonicalPath("/Overflow.mp4"))
        let scratch = try XCTUnwrap(deduplicator!.scratchDirectoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertFalse(try deduplicator!.insertCanonicalPath("/Cafe\u{301}.mp4"))
        XCTAssertFalse(try deduplicator!.insertCanonicalPath("/1.mp4"))
        XCTAssertFalse(try deduplicator!.insertCanonicalPath("/Caf\u{e9}.mp4"))
        XCTAssertFalse(try deduplicator!.insertCanonicalPath("/Cafe\u{301}.mp4"))
        XCTAssertTrue(try deduplicator!.insertCanonicalPath("/nul\0one.mp4"))
        XCTAssertTrue(try deduplicator!.insertCanonicalPath("/nul\0two.mp4"))
        XCTAssertFalse(try deduplicator!.insertCanonicalPath("/nul\0one.mp4"))
        XCTAssertTrue(try deduplicator!.insertCanonicalPath(""))
        XCTAssertFalse(try deduplicator!.insertCanonicalPath(""))
        XCTAssertEqual(
            deduplicator!.maximumResidentKeyCount,
            TemporaryPlaybackInputDeduplicator.Budget.maximumResidentKeyCount
        )
        XCTAssertLessThanOrEqual(
            deduplicator!.maximumResidentUTF8Bytes,
            TemporaryPlaybackInputDeduplicator.Budget.maximumResidentUTF8Bytes
        )
        deduplicator = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testByteBudgetSpillsAnOversizedKeyWithoutKeepingItResident() throws {
        let directory = try makeScratchParent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deduplicator = TemporaryPlaybackInputDeduplicator(temporaryDirectoryURL: directory)
        let path = String(
            repeating: "x",
            count: TemporaryPlaybackInputDeduplicator.Budget.maximumResidentUTF8Bytes + 1
        )
        XCTAssertTrue(try deduplicator.insertCanonicalPath(path))
        XCTAssertFalse(try deduplicator.insertCanonicalPath(path))
        XCTAssertNotNil(deduplicator.scratchDirectoryURL)
        XCTAssertEqual(deduplicator.maximumResidentKeyCount, 0)
        XCTAssertEqual(deduplicator.maximumResidentUTF8Bytes, 0)
    }

    func testScratchCreationFailureKeepsConfirmedMemoryKeysAndCreatesNothing()
        throws {
        let directory = try makeScratchParent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let occupied = directory.appendingPathComponent("Occupied")
        try Data([1]).write(to: occupied)
        let deduplicator = TemporaryPlaybackInputDeduplicator(temporaryDirectoryURL: occupied)
        for index in 0..<TemporaryPlaybackInputDeduplicator.Budget.maximumResidentKeyCount {
            XCTAssertTrue(try deduplicator.insertCanonicalPath("/\(index).mp4"))
        }
        XCTAssertThrowsError(try deduplicator.insertCanonicalPath("/Overflow.mp4"))
        XCTAssertFalse(try deduplicator.insertCanonicalPath("/0.mp4"))
        XCTAssertNil(deduplicator.scratchDirectoryURL)
        XCTAssertEqual(try Data(contentsOf: occupied), Data([1]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Occupied"])
    }

    private func makeScratchParent() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Muralume-InputDedupTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
