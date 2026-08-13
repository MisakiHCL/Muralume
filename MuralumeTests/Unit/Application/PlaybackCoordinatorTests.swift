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
            playbackRepeatBehavior: .queue,
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
            return .advanced
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

    func testRepeatCurrentDispositionSeeksWithoutReloadingQueueItem() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.itemEndedHandler = {
            .repeatCurrent
        }
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/repeat.mp4"),
                displayName: "Repeat"
            )
        )

        engine.emitItemEnded()

        XCTAssertEqual(engine.loadedSources.count, 1)
        XCTAssertEqual(engine.soughtTimes, [0])
        XCTAssertEqual(coordinator.currentTime, 0)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(engine.isPlaying)

        engine.emitItemEnded()
        XCTAssertEqual(engine.loadedSources.count, 1)
        XCTAssertEqual(engine.soughtTimes, [0, 0])
    }

    func testPausedTimelineSeekKeepsLastFrameUntilPlaybackIsRequested() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        var completionCount = 0
        coordinator.itemEndedHandler = {
            completionCount += 1
            return .advanced
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
        XCTAssertEqual(engine.soughtTimes, [120, 120])
        XCTAssertEqual(engine.seekModes, [.interactive, .exact])
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
            return .advanced
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
        XCTAssertEqual(engine.soughtTimes, [120, 42, 42])
        XCTAssertEqual(
            engine.seekModes,
            [.interactive, .interactive, .exact]
        )
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(engine.isPlaying)
    }

    func testTimelineSeekUsesInteractiveUpdatesAndExactFinalTarget() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        coordinator.beginTimelineSeek()
        coordinator.seek(to: 10)
        coordinator.seek(to: 20)
        coordinator.seek(to: 30)
        coordinator.endTimelineSeek()

        XCTAssertEqual(engine.soughtTimes, [10, 20, 30, 30])
        XCTAssertEqual(
            engine.seekModes,
            [.interactive, .interactive, .interactive, .exact]
        )
        XCTAssertEqual(coordinator.currentTime, 30)
        XCTAssertTrue(engine.isPlaying)
    }

    func testTimelineValueChangeWithoutEditingUsesExactSeek() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        coordinator.seek(to: 42)

        XCTAssertEqual(engine.soughtTimes, [42])
        XCTAssertEqual(engine.seekModes, [.exact])
        XCTAssertEqual(coordinator.currentTime, 42)
    }

    func testInteractiveSeekCoalescesPendingTargetsToTheLatest() async {
        var requests: [(TimeInterval, PlaybackSeekMode)] = []
        var completions: [PlaybackSeekCoalescer.Completion] = []
        let coalescer = PlaybackSeekCoalescer { seconds, mode, completion in
            requests.append((seconds, mode))
            completions.append(completion)
        }

        coalescer.seek(to: 10, mode: .interactive)
        coalescer.seek(to: 20, mode: .interactive)
        coalescer.seek(to: 30, mode: .interactive)

        XCTAssertEqual(requests.map { $0.0 }, [10])
        XCTAssertEqual(requests.map { $0.1 }, [.interactive])

        let firstCompletion = completions.removeFirst()
        firstCompletion()
        await Task.yield()

        XCTAssertEqual(requests.map { $0.0 }, [10, 30])
        XCTAssertEqual(
            requests.map { $0.1 },
            [.interactive, .interactive]
        )
    }

    func testExactSeekDiscardsPendingInteractiveTarget() async {
        var requests: [(TimeInterval, PlaybackSeekMode)] = []
        var completions: [PlaybackSeekCoalescer.Completion] = []
        let coalescer = PlaybackSeekCoalescer { seconds, mode, completion in
            requests.append((seconds, mode))
            completions.append(completion)
        }

        coalescer.seek(to: 10, mode: .interactive)
        coalescer.seek(to: 20, mode: .interactive)
        coalescer.seek(to: 40, mode: .exact)

        XCTAssertEqual(requests.map { $0.0 }, [10, 40])
        XCTAssertEqual(requests.map { $0.1 }, [.interactive, .exact])

        let supersededCompletion = completions.removeFirst()
        supersededCompletion()
        await Task.yield()

        XCTAssertEqual(requests.map { $0.0 }, [10, 40])
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
            return .advanced
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

    func testReopenDoesNotReviveMediaAfterGlobalSurfaceTimeout() async {
        let engine = TestPlaybackEngine()
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/global-surface-timeout.mp4"),
            displayName: "Global Surface Timeout"
        )
        engine.loadErrorsByURL[source.url] = .surfaceTimeout
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.registerPlayerSurface(TestPlaybackSurface(id: .player))

        let result = await coordinator.load(source)
        coordinator.dismissPlayerWindow()
        coordinator.restorePlayerWindow()
        await Task.yield()

        XCTAssertEqual(result, .globalFailure(.surfaceTimeout))
        XCTAssertEqual(coordinator.readiness, .failed(.surfaceTimeout))
        XCTAssertFalse(coordinator.hasPlayableMedia)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.attachedSurfaceID)
        XCTAssertEqual(engine.stopCount, 1)
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

        coordinator.setSuspended(true, for: .thermalPressure)
        coordinator.setSuspended(true, for: .displaySleeping)
        coordinator.setSuspended(false, for: .thermalPressure)

        XCTAssertFalse(engine.isPlaying)

        coordinator.setSuspended(false, for: .displaySleeping)
        XCTAssertTrue(engine.isPlaying)
    }

    func testSystemSuspensionPausesEveryPresentationAndPreservesIntent()
        async throws {
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
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(coordinator.isSystemSuspended)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertFalse(engine.isPlaying)

        try await coordinator.transitionToPlayer()
        XCTAssertFalse(engine.isPlaying)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertFalse(engine.isPlaying)

        coordinator.setSuspended(false, for: .screenLocked)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(coordinator.isSystemSuspended)
    }

    func testSystemSuspensionPublishesWhilePlaybackIsAlreadyPaused() {
        let coordinator = PlaybackCoordinator(engine: TestPlaybackEngine())
        var publishedStates: [Bool] = []
        let observation = coordinator.$isSystemSuspended
            .dropFirst()
            .sink { publishedStates.append($0) }

        coordinator.setSuspended(true, for: .displaySleeping)
        coordinator.setSuspended(false, for: .displaySleeping)

        XCTAssertEqual(publishedStates, [true, false])
        withExtendedLifetime(observation) {}
    }

    func testPlayerWindowSuspensionDoesNotPauseDesktopPlayback() async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        coordinator.setSuspended(true, for: .playerWindowMiniaturized)
        XCTAssertFalse(engine.isPlaying)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertTrue(engine.isPlaying)

        try await coordinator.transitionToPlayer()
        XCTAssertFalse(engine.isPlaying)

        coordinator.setSuspended(false, for: .playerWindowMiniaturized)
        XCTAssertTrue(engine.isPlaying)
    }

    func testDesktopCadenceReevaluatesMixedSuspensionReasons() async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        coordinator.setSuspended(true, for: .playerWindowMiniaturized)
        coordinator.setSuspended(true, for: .displaySleeping)

        try await coordinator.transitionToDesktop(desktopSurface)
        XCTAssertEqual(engine.progressCadence, .inactive)
        XCTAssertFalse(engine.isPlaying)

        coordinator.setSuspended(false, for: .displaySleeping)

        XCTAssertEqual(engine.progressCadence, .background)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(coordinator.isSystemSuspended)
    }

    func testMiniaturizedReturnPausesDuringAttachmentAndResumesOnFailure()
        async throws
    {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )
        try await coordinator.transitionToDesktop(desktopSurface)
        coordinator.setSuspended(true, for: .playerWindowMiniaturized)
        engine.shouldBlockAttachments = true

        let transition = Task {
            try await coordinator.transitionToPlayer()
        }
        for _ in 0..<1_000 where !engine.didBeginBlockedAttachment {
            await Task.yield()
        }

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.progressCadence, .inactive)

        transition.cancel()
        do {
            try await transition.value
            XCTFail("Expected the blocked attachment to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(coordinator.presentation, .desktop)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.progressCadence, .background)
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

    func testProgressCadenceTracksVisibleDesktopAndDismissedStates()
        async throws {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let desktopSurface = TestPlaybackSurface(id: .desktop)
        coordinator.registerPlayerSurface(playerSurface)
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/example.mp4"),
                displayName: "Example"
            )
        )

        try await coordinator.transitionToDesktop(desktopSurface)
        try await coordinator.transitionToPlayer()
        coordinator.dismissPlayerWindow()
        let hiddenTime = coordinator.currentTime
        engine.progressHandler?(hiddenTime + 10)

        XCTAssertEqual(coordinator.currentTime, hiddenTime)

        coordinator.restorePlayerWindow()
        await Task.yield()
        coordinator.stop()

        XCTAssertEqual(
            engine.progressCadenceChanges,
            [
                .inactive,
                .visible,
                .background,
                .visible,
                .inactive,
                .visible,
                .inactive
            ]
        )
        XCTAssertEqual(engine.progressCadence, .inactive)
    }

    func testDismissingPlayingWindowPausesAndResumesOriginalIntent() async {
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
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.attachedSurfaceID)

        coordinator.restorePlayerWindow()
        await Task.yield()

        XCTAssertFalse(coordinator.isPlayerWindowDismissed)
        XCTAssertEqual(coordinator.source, source)
        XCTAssertEqual(coordinator.currentTime, 42)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
    }

    func testDismissingPausedWindowKeepsItPausedAfterRestore() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/example.mp4"),
            displayName: "Example"
        )
        coordinator.registerPlayerSurface(playerSurface)
        await coordinator.load(source, autoplay: false)

        coordinator.dismissPlayerWindow()

        XCTAssertTrue(coordinator.isPlayerWindowDismissed)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.attachedSurfaceID)

        coordinator.restorePlayerWindow()
        await Task.yield()

        XCTAssertFalse(coordinator.isPlayerWindowDismissed)
        XCTAssertFalse(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
    }

    func testSurfaceTimeoutPreservesPlaybackAndCanRetryWithoutStoppingEngine()
        async
    {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/example.mp4"),
            displayName: "Example"
        )
        var reportedFailures: [PlaybackFailure] = []
        coordinator.playbackFailureHandler = {
            reportedFailures.append($0)
        }

        coordinator.registerPlayerSurface(playerSurface)
        await coordinator.load(source)
        engine.progressHandler?(42)
        coordinator.dismissPlayerWindow()
        engine.attachmentErrorsBySurfaceID[.player] = .surfaceTimeout

        coordinator.restorePlayerWindow()
        for _ in 0..<1_000
            where coordinator.readiness != .failed(.surfaceTimeout) {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.readiness, .failed(.surfaceTimeout))
        XCTAssertEqual(coordinator.source, source)
        XCTAssertEqual(coordinator.currentTime, 42)
        XCTAssertEqual(coordinator.duration, 120)
        XCTAssertTrue(coordinator.hasPlayableMedia)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(reportedFailures, [.surfaceTimeout])

        engine.attachmentErrorsBySurfaceID[.player] = nil
        coordinator.restorePlayerWindow()
        for _ in 0..<1_000
            where coordinator.readiness != .ready || !engine.isPlaying {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertEqual(coordinator.currentTime, 42)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
        XCTAssertEqual(engine.stopCount, 0)
    }

    func testReopenDuringSupersededLoadAttachmentRetriesCurrentSurface()
        async {
        let engine = TestPlaybackEngine()
        engine.shouldBlockAttachments = true
        engine.blockedAttachmentError = .superseded
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        let source = ResolvedMediaSource(
            url: URL(fileURLWithPath: "/tmp/reopen-during-attach.mp4"),
            displayName: "Reopen During Attach"
        )
        coordinator.registerPlayerSurface(playerSurface)

        let loadTask = Task {
            await coordinator.load(source)
        }
        for _ in 0..<1_000 where !engine.didBeginBlockedAttachment {
            await Task.yield()
        }
        XCTAssertTrue(engine.didBeginBlockedAttachment)

        coordinator.dismissPlayerWindow()
        coordinator.restorePlayerWindow()

        let loadResult = await loadTask.value
        XCTAssertEqual(loadResult, .loaded)
        for _ in 0..<1_000
            where coordinator.readiness != .ready || !engine.isPlaying {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.readiness, .ready)
        XCTAssertEqual(coordinator.source, source)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(engine.attachedSurfaceID, .player)
        XCTAssertGreaterThanOrEqual(engine.attachedSurfaceIDs.count, 2)
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

    func testDismissDuringReplacementLoadPreservesPlayingIntent() async {
        let engine = TestPlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playerSurface = TestPlaybackSurface(id: .player)
        coordinator.registerPlayerSurface(playerSurface)
        await coordinator.load(
            ResolvedMediaSource(
                url: URL(fileURLWithPath: "/tmp/first.mp4"),
                displayName: "First"
            )
        )
        engine.shouldBlockLoads = true

        let replacementLoad = Task {
            await coordinator.load(
                ResolvedMediaSource(
                    url: URL(fileURLWithPath: "/tmp/second.mp4"),
                    displayName: "Second"
                )
            )
        }
        while !engine.didBeginBlockedLoad {
            await Task.yield()
        }

        coordinator.dismissPlayerWindow()
        engine.finishBlockedLoad()
        let loadResult = await replacementLoad.value
        XCTAssertEqual(loadResult, .loaded)

        XCTAssertTrue(coordinator.isPlayerWindowDismissed)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(engine.attachedSurfaceID)

        coordinator.restorePlayerWindow()
        await Task.yield()

        XCTAssertFalse(coordinator.isPlayerWindowDismissed)
        XCTAssertTrue(coordinator.isPlaybackRequested)
        XCTAssertTrue(engine.isPlaying)
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
