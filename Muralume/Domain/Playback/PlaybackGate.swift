struct PlaybackGate: Equatable, Sendable {
    private(set) var intent: PlaybackIntent = .paused
    private(set) var suspensionReasons: Set<PlaybackSuspensionReason> = []
    private(set) var isTerminating = false

    var shouldPlay: Bool {
        intent == .playing && suspensionReasons.isEmpty && !isTerminating
    }

    func shouldPlay(
        ignoring ignoredReason: PlaybackSuspensionReason
    ) -> Bool {
        shouldPlay(ignoring: [ignoredReason])
    }

    func shouldPlay(
        ignoring ignoredReasons: Set<PlaybackSuspensionReason>
    ) -> Bool {
        intent == .playing
            && !isTerminating
            && suspensionReasons.isSubset(of: ignoredReasons)
    }

    mutating func setIntent(_ intent: PlaybackIntent) {
        guard !isTerminating else {
            return
        }
        self.intent = intent
    }

    @discardableResult
    mutating func setSuspended(
        _ suspended: Bool,
        for reason: PlaybackSuspensionReason
    ) -> Bool {
        guard !isTerminating else {
            return false
        }
        if suspended {
            return suspensionReasons.insert(reason).inserted
        } else {
            return suspensionReasons.remove(reason) != nil
        }
    }

    mutating func terminate() {
        isTerminating = true
        intent = .paused
        suspensionReasons.removeAll()
    }
}
