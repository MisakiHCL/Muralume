import XCTest
@testable import Muralume

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    func testInitialPreferencesApplyWithoutMediaAndPersistCompleteAudioState() {
        let engine = TestPlaybackEngine()
        let initialPreferences = AppPreferences(
            audio: PlaybackAudioPreferences(
                volume: .muted,
                isMuted: false,
                restorableVolume: PlaybackVolume(rawValue: 0.4)
            ),
            playbackRate: PlaybackRate(rawValue: 1.5),
            playbackOrder: .shuffled,
            librarySort: MediaLibrarySort(),
            language: .system
        )
        let preferencesStore = TestAppPreferencesStore(
            preferences: initialPreferences
        )
        let coordinator = PlaybackCoordinator(
            engine: engine,
            initialPreferences: initialPreferences,
            preferencesStore: preferencesStore
        )

        XCTAssertEqual(coordinator.readiness, .empty)
        XCTAssertEqual(coordinator.settings.volume, .muted)
        XCTAssertFalse(coordinator.settings.isMuted)
        XCTAssertEqual(
            coordinator.settings.restorableVolume,
            PlaybackVolume(rawValue: 0.4)
        )
        XCTAssertEqual(engine.volume, .muted)
        XCTAssertFalse(engine.isMuted)

        coordinator.setMuted(true)
        coordinator.setMuted(false)

        XCTAssertEqual(
            coordinator.settings.volume,
            PlaybackVolume(rawValue: 0.4)
        )
        XCTAssertEqual(
            preferencesStore.savedAudio,
            [
                PlaybackAudioPreferences(
                    volume: .muted,
                    isMuted: true,
                    restorableVolume: PlaybackVolume(rawValue: 0.4)
                ),
                PlaybackAudioPreferences(
                    volume: PlaybackVolume(rawValue: 0.4),
                    isMuted: false,
                    restorableVolume: PlaybackVolume(rawValue: 0.4)
                )
            ]
        )
    }

    func testRatePersistsOnlyWhenItChangesAndMediaLoadDoesNotRewriteIt() async {
        let engine = TestPlaybackEngine()
        let preferencesStore = TestAppPreferencesStore()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            preferencesStore: preferencesStore
        )

        coordinator.setRate(PlaybackPolicy.defaultRate)
        coordinator.setRate(PlaybackRate(rawValue: 1.5))
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        XCTAssertEqual(
            preferencesStore.savedPlaybackRates,
            [PlaybackRate(rawValue: 1.5)]
        )
        XCTAssertTrue(preferencesStore.savedAudio.isEmpty)
    }

    func testVolumeCanChangeAndPersistWithoutLoadedMedia() async {
        let engine = TestPlaybackEngine()
        let preferencesStore = TestAppPreferencesStore()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            preferencesStore: preferencesStore,
            audioPreferencesPersistenceDelay: .milliseconds(10)
        )
        let volume = PlaybackVolume(rawValue: 0.36)

        coordinator.setVolume(volume)

        XCTAssertEqual(coordinator.readiness, .empty)
        XCTAssertEqual(coordinator.settings.volume, volume)
        XCTAssertEqual(engine.volume, volume)
        XCTAssertTrue(preferencesStore.savedAudio.isEmpty)

        await waitForAudioPreferenceSaves(
            preferencesStore,
            expectedCount: 1
        )

        XCTAssertEqual(
            preferencesStore.savedAudio,
            [
                PlaybackAudioPreferences(
                    volume: volume,
                    isMuted: false,
                    restorableVolume: volume
                )
            ]
        )
    }

    func testRapidVolumeChangesCoalesceIntoFinalPreferenceWrite() async {
        let engine = TestPlaybackEngine()
        let preferencesStore = TestAppPreferencesStore()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            preferencesStore: preferencesStore,
            audioPreferencesPersistenceDelay: .milliseconds(20)
        )
        let finalVolume = PlaybackVolume(rawValue: 0.72)

        coordinator.setVolume(PlaybackVolume(rawValue: 0.2))
        coordinator.setVolume(PlaybackVolume(rawValue: 0.48))
        coordinator.setVolume(finalVolume)

        XCTAssertEqual(engine.volume, finalVolume)
        XCTAssertTrue(preferencesStore.savedAudio.isEmpty)

        await waitForAudioPreferenceSaves(
            preferencesStore,
            expectedCount: 1
        )

        XCTAssertEqual(
            preferencesStore.savedAudio,
            [
                PlaybackAudioPreferences(
                    volume: finalVolume,
                    isMuted: false,
                    restorableVolume: finalVolume
                )
            ]
        )
    }

    func testShutdownFlushesPendingVolumePreferenceWithoutDuplicateWrite() async {
        let preferencesStore = TestAppPreferencesStore()
        let coordinator = PlaybackCoordinator(
            engine: TestPlaybackEngine(),
            preferencesStore: preferencesStore,
            audioPreferencesPersistenceDelay: .milliseconds(20)
        )
        let finalVolume = PlaybackVolume(rawValue: 0.64)

        coordinator.setVolume(PlaybackVolume(rawValue: 0.32))
        coordinator.setVolume(finalVolume)
        XCTAssertTrue(preferencesStore.savedAudio.isEmpty)

        coordinator.shutdown()

        XCTAssertEqual(
            preferencesStore.savedAudio,
            [
                PlaybackAudioPreferences(
                    volume: finalVolume,
                    isMuted: false,
                    restorableVolume: finalVolume
                )
            ]
        )

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(preferencesStore.savedAudio.count, 1)
    }

    func testMuteImmediatelySupersedesPendingVolumePreferenceWrite() async {
        let preferencesStore = TestAppPreferencesStore()
        let coordinator = PlaybackCoordinator(
            engine: TestPlaybackEngine(),
            preferencesStore: preferencesStore,
            audioPreferencesPersistenceDelay: .milliseconds(20)
        )
        let volume = PlaybackVolume(rawValue: 0.44)

        coordinator.setVolume(volume)
        XCTAssertTrue(preferencesStore.savedAudio.isEmpty)

        coordinator.setMuted(true)

        XCTAssertEqual(
            preferencesStore.savedAudio,
            [
                PlaybackAudioPreferences(
                    volume: .muted,
                    isMuted: true,
                    restorableVolume: volume
                )
            ]
        )

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(preferencesStore.savedAudio.count, 1)
    }

    func testPendingAudioSaveDoesNotRetainCoordinatorAfterDeinit() async {
        let preferencesStore = TestAppPreferencesStore()
        var coordinator: PlaybackCoordinator? = PlaybackCoordinator(
            engine: TestPlaybackEngine(),
            preferencesStore: preferencesStore,
            audioPreferencesPersistenceDelay: .milliseconds(20)
        )
        weak var weakCoordinator = coordinator

        coordinator?.setVolume(PlaybackVolume(rawValue: 0.5))
        coordinator = nil

        XCTAssertNil(weakCoordinator)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(preferencesStore.savedAudio.isEmpty)
    }

    func testPlayableMediaSurvivesReplacementLoadingAndItemFailure() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let firstSource = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/first.mp4"),
            displayName: "First"
        )
        let secondSource = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/second.mp4"),
            displayName: "Second"
        )

        await coordinator.load(firstSource)
        XCTAssertTrue(coordinator.hasPlayableMedia)
        XCTAssertTrue(coordinator.isPlaybackRequested)

        engine.shouldBlockLoads = true
        let replacementLoad = Task {
            await coordinator.load(secondSource)
        }
        while !engine.didBeginBlockedLoad {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.readiness, .loading)
        XCTAssertTrue(coordinator.hasPlayableMedia)

        engine.finishBlockedLoad()
        _ = await replacementLoad.value
        engine.shouldBlockLoads = false
        engine.loadErrorsByURL[secondSource.url] = .cannotOpen

        let failure = await coordinator.load(secondSource)

        XCTAssertEqual(failure, .mediaFailure(.cannotOpen))
        XCTAssertTrue(coordinator.hasPlayableMedia)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
    }

    func testPlayingTimelineSeekToEndDefersCompletionUntilRelease() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var completionCount = 0
        coordinator.itemEndedHandler = {
            completionCount += 1
            return true
        }
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        coordinator.beginTimelineSeek()
        coordinator.seek(to: 120)
        engine.emitItemEnded()

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(coordinator.currentTime, 120)

        coordinator.endTimelineSeek()
        engine.emitItemEnded()

        XCTAssertEqual(completionCount, 1)
    }

    func testPausedTimelineSeekKeepsLastFrameUntilPlaybackIsRequested() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var completionCount = 0
        coordinator.itemEndedHandler = {
            completionCount += 1
            return true
        }
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        coordinator.setPlaybackIntent(.paused)

        coordinator.beginTimelineSeek()
        coordinator.seek(to: 120)
        engine.emitItemEnded()
        coordinator.endTimelineSeek()
        engine.emitItemEnded()

        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(coordinator.currentTime, 120)
        XCTAssertEqual(engine.soughtTimes, [120])
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)

        coordinator.setPlaybackIntent(.playing)

        XCTAssertEqual(completionCount, 1)
    }

    func testPlayingTimelineSeekBackFromEndResumesWithoutCompleting() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var completionCount = 0
        coordinator.itemEndedHandler = {
            completionCount += 1
            return true
        }
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        coordinator.beginTimelineSeek()
        coordinator.seek(to: 120)
        engine.emitItemEnded()
        coordinator.seek(to: 42)
        coordinator.endTimelineSeek()

        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(coordinator.currentTime, 42)
        XCTAssertEqual(engine.soughtTimes, [120, 42])
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(engine.isPlaying)
    }

    func testLoadingReplacementCancelsTimelineSeekInteraction() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/first.mp4"),
                displayName: "First"
            )
        )
        coordinator.beginTimelineSeek()
        XCTAssertFalse(engine.isPlaying)

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/second.mp4"),
                displayName: "Second"
            )
        )
        coordinator.endTimelineSeek()

        XCTAssertEqual(coordinator.source?.displayName, "Second")
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(engine.isPlaying)
    }

    func testHandledEngineFailureCancelsTimelineSeekBeforeRelease() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var handledFailureCount = 0
        var completionCount = 0
        coordinator.itemFailureHandler = { _ in
            handledFailureCount += 1
            return true
        }
        coordinator.itemEndedHandler = {
            completionCount += 1
            return true
        }
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        coordinator.beginTimelineSeek()
        coordinator.seek(to: 120)
        engine.emitFailure(.cannotOpen)
        coordinator.endTimelineSeek()

        XCTAssertEqual(handledFailureCount, 1)
        XCTAssertEqual(completionCount, 0)
    }

    func testInitialMediaFailureNeverMarksMediaPlayable() async {
        let engine = TestPlaybackEngine()
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/broken.mp4"),
            displayName: "Broken"
        )
        engine.loadErrorsByURL[source.url] = .cannotOpen
        let coordinator = PlaybackCoordinator(engine: engine)

        let result = await coordinator.load(source)

        XCTAssertEqual(result, .mediaFailure(.cannotOpen))
        XCTAssertFalse(coordinator.hasPlayableMedia)
        XCTAssertFalse(coordinator.isPlaybackRequested)
    }

    func testTerminalPlaybackPathsClearPlayableMedia() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/example.mp4"),
            displayName: "Example"
        )

        await coordinator.load(source)
        coordinator.stop()
        XCTAssertFalse(coordinator.hasPlayableMedia)

        await coordinator.load(source)
        coordinator.finishQueue(with: .cannotOpen)
        XCTAssertFalse(coordinator.hasPlayableMedia)

        await coordinator.load(source)
        coordinator.shutdown()
        XCTAssertFalse(coordinator.hasPlayableMedia)
    }

    func testMuteSetsVolumeToZeroAndUnmuteRestoresPreviousVolume() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let previousVolume = PlaybackVolume(rawValue: 0.4)

        coordinator.setVolume(previousVolume)
        coordinator.setMuted(true)

        XCTAssertTrue(coordinator.settings.isMuted)
        XCTAssertEqual(coordinator.settings.volume, .muted)
        XCTAssertTrue(engine.isMuted)
        XCTAssertEqual(engine.volume, .muted)

        coordinator.setMuted(false)

        XCTAssertFalse(coordinator.settings.isMuted)
        XCTAssertEqual(coordinator.settings.volume, previousVolume)
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, previousVolume)
    }

    func testRepeatedMuteAndZeroAdjustmentPreserveRestorableVolume() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let previousVolume = PlaybackVolume(rawValue: 0.4)

        coordinator.setVolume(previousVolume)
        coordinator.setMuted(true)
        coordinator.setMuted(true)
        coordinator.setVolume(.muted)
        coordinator.setMuted(false)

        XCTAssertFalse(coordinator.settings.isMuted)
        XCTAssertEqual(coordinator.settings.volume, previousVolume)
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, previousVolume)
    }

    func testNonzeroVolumeAdjustmentWhileMutedUnmutesAndBecomesRestorable() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let adjustedVolume = PlaybackVolume(rawValue: 0.25)

        coordinator.setMuted(true)
        coordinator.setVolume(adjustedVolume)

        XCTAssertFalse(coordinator.settings.isMuted)
        XCTAssertEqual(coordinator.settings.volume, adjustedVolume)
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, adjustedVolume)

        coordinator.setMuted(true)
        coordinator.setMuted(false)

        XCTAssertEqual(coordinator.settings.volume, adjustedVolume)
        XCTAssertEqual(engine.volume, adjustedVolume)
    }

    func testVolumeAdjustmentUsesFixedStepAndClampsAtBounds() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)

        coordinator.adjustVolume(by: -PlaybackPolicy.volumeStep)

        XCTAssertEqual(
            coordinator.settings.volume.rawValue,
            0.9,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            engine.volume.rawValue,
            0.9,
            accuracy: 0.0001
        )

        coordinator.adjustVolume(by: PlaybackPolicy.volumeStep)
        coordinator.adjustVolume(by: PlaybackPolicy.volumeStep)

        XCTAssertEqual(coordinator.settings.volume, .full)
        XCTAssertEqual(engine.volume, .full)

        for _ in 0..<20 {
            coordinator.adjustVolume(by: -PlaybackPolicy.volumeStep)
        }

        XCTAssertEqual(coordinator.settings.volume, .muted)
        XCTAssertEqual(engine.volume, .muted)
    }

    func testIncreasingVolumeWhileMutedUnmutesAtFirstStep() {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.setMuted(true)

        coordinator.adjustVolume(by: PlaybackPolicy.volumeStep)

        XCTAssertFalse(coordinator.settings.isMuted)
        XCTAssertEqual(
            coordinator.settings.volume.rawValue,
            PlaybackPolicy.volumeStep,
            accuracy: 0.0001
        )
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(
            engine.volume.rawValue,
            PlaybackPolicy.volumeStep,
            accuracy: 0.0001
        )
    }

    func testLoadAfterStopReattachesTheRegisteredPlayerSurface() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)

        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()
        coordinator.stop()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
        XCTAssertEqual(engine.attachedSurfaceIDs, [.player])
    }

    func testDesktopRoundTripUsesTheSameEngineAndRestoresPlayerSettings() async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        coordinator.setVolume(PlaybackVolume(rawValue: 0.4))
        coordinator.setMuted(false)
        coordinator.setRate(PlaybackRate(rawValue: 1.5))

        try await coordinator.transitionToDesktop(desktopSurface)

        XCTAssertEqual(coordinator.presentation, .desktop)
        XCTAssertTrue(engine.isMuted)
        XCTAssertEqual(engine.rate, PlaybackRate(rawValue: 1.5))

        coordinator.setRate(PlaybackRate(rawValue: 2))
        XCTAssertEqual(engine.rate, PlaybackRate(rawValue: 2))

        try await coordinator.transitionToPlayer()

        XCTAssertEqual(coordinator.presentation, .player)
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.volume, PlaybackVolume(rawValue: 0.4))
        XCTAssertEqual(engine.rate, PlaybackRate(rawValue: 2))
        XCTAssertTrue(engine.attachedSurfaceIDs.contains(.desktop))
        XCTAssertEqual(engine.attachedSurfaceIDs.last, .player)
    }

    func testRemovingOnlyOneSystemReasonDoesNotResumeDesktopPlayback() async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        try await coordinator.transitionToDesktop(desktopSurface)

        coordinator.setSuspended(true, for: .screenLocked)
        coordinator.setSuspended(true, for: .displaySleeping)
        coordinator.setSuspended(false, for: .screenLocked)

        XCTAssertFalse(engine.isPlaying)

        coordinator.setSuspended(false, for: .displaySleeping)
        XCTAssertTrue(engine.isPlaying)
    }

    func testSuspensionRecordedInPlayerRemainsEffectiveAcrossDesktopRoundTrips() async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        coordinator.setSuspended(true, for: .screenLocked)
        XCTAssertTrue(engine.isPlaying)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertFalse(engine.isPlaying)

        try await coordinator.transitionToPlayer()
        XCTAssertTrue(engine.isPlaying)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertFalse(engine.isPlaying)

        coordinator.setSuspended(false, for: .screenLocked)
        XCTAssertTrue(engine.isPlaying)
    }

    func testEngineFailureResetsPlaybackAndNotifiesTheApp() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var reportedFailure: PlaybackFailure?
        coordinator.playbackFailureHandler = { failure in
            reportedFailure = failure
        }

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        engine.emitFailure(.cannotOpen)

        XCTAssertEqual(coordinator.readiness, .failed(.cannotOpen))
        XCTAssertEqual(coordinator.presentation, .player)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(coordinator.isActuallyPlaying)
        XCTAssertFalse(coordinator.hasPlayableMedia)
        XCTAssertEqual(reportedFailure, .cannotOpen)
    }

    func testDismissingPlayerWindowPausesWithoutClearingProcessState() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/example.mp4"),
            displayName: "Example"
        )
        coordinator.registerPlayerSurface(playerSurface)
        await coordinator.load(source)
        engine.progressHandler?(42)

        coordinator.dismissPlayerWindow()

        XCTAssertTrue(coordinator.isPlayerWindowDismissed)
        XCTAssertEqual(coordinator.source, source)
        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertEqual(coordinator.presentation, .player)
        XCTAssertEqual(coordinator.currentTime, 42)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.attachedSurfaceID)

        coordinator.restorePlayerWindow()
        await Task.yield()

        XCTAssertFalse(coordinator.isPlayerWindowDismissed)
        XCTAssertEqual(coordinator.source, source)
        XCTAssertEqual(coordinator.currentTime, 42)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
    }

    func testDismissDuringLoadRevokesAutoplayAfterImmediateReopen() async {
        let engine = TestPlaybackEngine()
        engine.shouldBlockLoads = true
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        coordinator.registerPlayerSurface(playerSurface)
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/example.mp4"),
            displayName: "Example"
        )

        let loadTask = Task {
            await coordinator.load(source)
        }
        while !engine.didBeginBlockedLoad {
            await Task.yield()
        }

        coordinator.dismissPlayerWindow()
        coordinator.restorePlayerWindow()
        engine.finishBlockedLoad()

        let loadResult = await loadTask.value
        XCTAssertEqual(loadResult, .loaded)
        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertFalse(coordinator.isPlayerWindowDismissed)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
    }

    func testShutdownCannotBeRolledBackByACancelledTransition() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await Task.yield()

        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        engine.shouldBlockAttachments = true

        let transition = Task {
            try await coordinator.transitionToDesktop(desktopSurface)
        }
        while !engine.didBeginBlockedAttachment {
            await Task.yield()
        }

        coordinator.shutdown()
        transition.cancel()
        _ = try? await transition.value

        XCTAssertEqual(coordinator.presentation, .terminating)
        XCTAssertFalse(engine.isPlaying)
    }

    private func waitForAudioPreferenceSaves(
        _ preferencesStore: TestAppPreferencesStore,
        expectedCount: Int
    ) async {
        for _ in 0..<100 {
            if preferencesStore.savedAudio.count >= expectedCount {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(
            "Timed out waiting for \(expectedCount) audio preference saves"
        )
    }
}
