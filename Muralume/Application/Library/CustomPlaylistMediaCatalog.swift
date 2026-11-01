import Combine
import Foundation

struct CustomPlaylistMediaCatalogSnapshot: Sendable {
    var items: [LibraryMediaItem] = []
    var itemsByEntryID: [CustomPlaylistEntry.ID: LibraryMediaItem] = [:]
    var issuesByEntryID: [CustomPlaylistEntry.ID: CustomPlaylistMediaIssue] = [:]
    var authorizedRootIDs: Set<MediaLibraryRoot.ID> = []
    var revision: UInt64 = 0
    var availabilityRevision: UInt64 = 0
}

/// Owns one resolver request and one latest pending collection. Cancelled
/// native readers retain their own leases until their real work ends.
@MainActor
final class CustomPlaylistMediaCatalog {
    @Published private(set) var snapshot = CustomPlaylistMediaCatalogSnapshot()
    var didResolve: ((CustomPlaylistMediaResolution) -> Void)?

    private let resolver: any CustomPlaylistMediaAccessResolving
    private var requestedGrants: [CustomPlaylistMediaGrant]?
    private var requestedEntries: [CustomPlaylistEntry]?
    private var pending: (generation: UInt64, collection: CustomPlaylistCollection)?
    private var generation: UInt64 = 0
    private var drainTask: Task<Void, Never>?
    private var worker: Task<CustomPlaylistMediaResolution, Never>?
    private var isShutDown = false

    init(resolver: any CustomPlaylistMediaAccessResolving) {
        self.resolver = resolver
    }

    deinit {
        worker?.cancel()
        drainTask?.cancel()
    }

    func update(_ collection: CustomPlaylistCollection, force: Bool = false) {
        let entries = collection.allEntries
        guard !isShutDown,
              force || requestedGrants != collection.accessGrants || requestedEntries != entries else { return }
        requestedGrants = collection.accessGrants
        requestedEntries = entries
        generation &+= 1
        pending = (generation, collection)
        worker?.cancel()
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self, resolver] in
            while let request = self?.takePending() {
                let grants = request.collection.accessGrants
                let entries = request.collection.allEntries
                let worker = Task { @MainActor in
                    await resolver.resolve(grants: grants, entries: entries)
                }
                self?.worker = worker
                let result = await worker.value
                guard let self else { return }
                self.worker = nil
                guard !self.isShutDown, !worker.isCancelled,
                      self.generation == request.generation else { continue }
                self.publish(result, entries: entries)
                self.didResolve?(result)
            }
            self?.drainTask = nil
        }
    }

    func waitForResolution() async {
        await drainTask?.value
    }

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        generation &+= 1
        pending = nil
        worker?.cancel()
        await drainTask?.value
        drainTask = nil
        didResolve = nil
        requestedGrants = nil
        requestedEntries = nil
        await resolver.shutdown()
        snapshot = CustomPlaylistMediaCatalogSnapshot()
    }

    private func takePending() -> (generation: UInt64, collection: CustomPlaylistCollection)? {
        defer { pending = nil }
        return pending
    }

    private func publish(_ resolution: CustomPlaylistMediaResolution, entries: [CustomPlaylistEntry]) {
        let validIDs = Set(entries.map(\.id))
        let byEntry = resolution.itemsByEntryID.filter { validIDs.contains($0.key) }
        var issues = resolution.issuesByEntryID.filter { validIDs.contains($0.key) }
        for entry in entries where byEntry[entry.id] == nil && issues[entry.id] == nil {
            issues[entry.id] = entry.accessGrantID == nil ? .authorizationRequired : .temporarilyUnavailable
        }
        let contentChanged = snapshot.itemsByEntryID != byEntry
            || snapshot.authorizedRootIDs != resolution.authorizedRootIDs
        let issuesChanged = snapshot.issuesByEntryID != issues
        guard contentChanged || issuesChanged else { return }
        var seen: Set<LibraryMediaItem.ID> = []
        let items = entries.compactMap { byEntry[$0.id] }.filter { seen.insert($0.id).inserted }
        snapshot = CustomPlaylistMediaCatalogSnapshot(
            items: items, itemsByEntryID: byEntry, issuesByEntryID: issues,
            authorizedRootIDs: resolution.authorizedRootIDs,
            revision: snapshot.revision &+ (contentChanged ? 1 : 0),
            availabilityRevision: snapshot.availabilityRevision &+ (issuesChanged ? 1 : 0)
        )
    }
}
