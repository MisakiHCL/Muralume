struct PlaybackGate: Equatable, Sendable {
    private(set) var intent: PlaybackIntent = .paused
    private(set) var suspensionReasons: Set<PlaybackSuspensionReason> = []
    private(set) var isTerminating = false

    var shouldPlay: Bool {
        intent == .playing && suspensionReasons.isEmpty && !isTerminating
    }

    mutating func setIntent(_ intent: PlaybackIntent) {
        guard !isTerminating else {
            return
        }
        self.intent = intent
    }

    mutating func setSuspended(_ suspended: Bool, for reason: PlaybackSuspensionReason) {
        guard !isTerminating else {
            return
        }
        if suspended {
            suspensionReasons.insert(reason)
        } else {
            suspensionReasons.remove(reason)
        }
    }

    mutating func terminate() {
        isTerminating = true
        intent = .paused
        suspensionReasons.removeAll()
    }
}
