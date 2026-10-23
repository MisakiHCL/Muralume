import AVFoundation
import Foundation

@MainActor
struct AVFoundationMediaSelectionContext {
    let item: AVPlayerItem
    let audioGroup: AVMediaSelectionGroup?
    let subtitleGroup: AVMediaSelectionGroup?
    let audioOptions: [PlaybackMediaOption]
    let subtitleOptions: [PlaybackMediaOption]

    private let audioOptionsByID: [
        PlaybackMediaOptionID: AVMediaSelectionOption
    ]
    private let subtitleOptionsByID: [
        PlaybackMediaOptionID: AVMediaSelectionOption
    ]
    private(set) var audioSelection: PlaybackAudioSelection = .automatic
    private(set) var subtitleSelection: PlaybackSubtitleSelection = .automatic

    init(
        item: AVPlayerItem,
        audioGroup: AVMediaSelectionGroup?,
        subtitleGroup: AVMediaSelectionGroup?,
        generation: UInt64
    ) {
        self.item = item
        self.audioGroup = audioGroup
        self.subtitleGroup = subtitleGroup

        let audioMappings = Self.makeOptions(
            group: audioGroup,
            prefix: "audio-\(generation)"
        )
        audioOptions = audioMappings.options
        audioOptionsByID = audioMappings.optionsByID

        let subtitleMappings = Self.makeOptions(
            group: subtitleGroup,
            prefix: "subtitle-\(generation)",
            hidesAssociatedForcedSubtitleOptions: true
        )
        subtitleOptions = subtitleMappings.options
        subtitleOptionsByID = subtitleMappings.optionsByID

    }

    var selectedSubtitleRequest: (
        id: PlaybackMediaOptionID, language: String, selectableLanguages: [String]
    )? {
        let languages = subtitleOptions.compactMap {
            EmbeddedSubtitleLanguage.primaryIdentifier($0.languageIdentifier)
        }
        guard languages.count == subtitleOptions.count,
              Set(languages).count == languages.count,
              let id = selectedOptionID(
                group: subtitleGroup, optionsByID: subtitleOptionsByID
              ), let option = subtitleOptions.first(where: { $0.id == id }),
              let language = EmbeddedSubtitleLanguage.primaryIdentifier(
                option.languageIdentifier
              ) else { return nil }
        return (id, language, languages)
    }

    var state: PlaybackMediaSelectionState {
        PlaybackMediaSelectionState(
            audioOptions: audioOptions,
            subtitleOptions: subtitleOptions,
            audioSelection: audioSelection,
            subtitleSelection: subtitleSelection,
            effectiveAudioOptionID: selectedOptionID(
                group: audioGroup,
                optionsByID: audioOptionsByID
            ),
            effectiveSubtitleOptionID: selectedOptionID(
                group: subtitleGroup,
                optionsByID: subtitleOptionsByID
            ),
            allowsEmptySubtitleSelection:
                subtitleGroup?.allowsEmptySelection ?? true
        )
    }

    mutating func selectAudio(_ selection: PlaybackAudioSelection) {
        guard let audioGroup else {
            return
        }
        switch selection {
        case .automatic:
            item.selectMediaOptionAutomatically(in: audioGroup)
        case let .option(id):
            guard let option = audioOptionsByID[id] else {
                return
            }
            item.select(option, in: audioGroup)
        }
        audioSelection = selection
    }

    mutating func selectSubtitles(
        _ selection: PlaybackSubtitleSelection
    ) {
        guard let subtitleGroup else {
            return
        }
        switch selection {
        case .automatic:
            item.selectMediaOptionAutomatically(in: subtitleGroup)
        case .off:
            guard subtitleGroup.allowsEmptySelection else {
                return
            }
            item.select(nil, in: subtitleGroup)
        case let .option(id):
            guard let option = subtitleOptionsByID[id] else {
                return
            }
            item.select(option, in: subtitleGroup)
        }
        subtitleSelection = selection
    }

    private func selectedOptionID(
        group: AVMediaSelectionGroup?,
        optionsByID: [PlaybackMediaOptionID: AVMediaSelectionOption]
    ) -> PlaybackMediaOptionID? {
        guard let group,
              let selectedOption = item.currentMediaSelection
                .selectedMediaOption(in: group) else {
            return nil
        }
        return optionsByID.first { _, option in
            option === selectedOption
        }?.key
    }

    private static func makeOptions(
        group: AVMediaSelectionGroup?,
        prefix: String,
        hidesAssociatedForcedSubtitleOptions: Bool = false
    ) -> (
        options: [PlaybackMediaOption],
        optionsByID: [PlaybackMediaOptionID: AVMediaSelectionOption]
    ) {
        guard let group else {
            return ([], [:])
        }

        let groupOptions = hidesAssociatedForcedSubtitleOptions
            ? userSelectableSubtitleOptions(in: group)
            : group.options
        var options: [PlaybackMediaOption] = []
        var optionsByID: [PlaybackMediaOptionID: AVMediaSelectionOption] = [:]
        options.reserveCapacity(groupOptions.count)
        optionsByID.reserveCapacity(groupOptions.count)

        for (index, option) in groupOptions.enumerated() {
            let id = PlaybackMediaOptionID(
                rawValue: "\(prefix)-\(index)"
            )
            options.append(
                PlaybackMediaOption(
                    id: id,
                    displayName: option.displayName,
                    languageIdentifier: option.extendedLanguageTag
                        ?? option.locale?.identifier,
                    characteristics: characteristics(of: option)
                )
            )
            optionsByID[id] = option
        }
        return (options, optionsByID)
    }

    private static func userSelectableSubtitleOptions(
        in group: AVMediaSelectionGroup
    ) -> [AVMediaSelectionOption] {
        let associatedForcedOptionIDs = Set(
            group.options.compactMap { option -> ObjectIdentifier? in
                guard !option.hasMediaCharacteristic(
                    .containsOnlyForcedSubtitles
                ),
                let associatedOption = option.associatedMediaSelectionOption(
                    in: group
                ),
                associatedOption.hasMediaCharacteristic(
                    .containsOnlyForcedSubtitles
                ) else {
                    return nil
                }
                return ObjectIdentifier(associatedOption)
            }
        )
        return group.options.filter {
            !associatedForcedOptionIDs.contains(ObjectIdentifier($0))
        }
    }

    private static func characteristics(
        of option: AVMediaSelectionOption
    ) -> Set<PlaybackMediaOptionCharacteristic> {
        var characteristics: Set<PlaybackMediaOptionCharacteristic> = []
        if option.hasMediaCharacteristic(.describesVideoForAccessibility) {
            characteristics.insert(.audioDescription)
        }
        if option.hasMediaCharacteristic(.dubbedTranslation)
            || option.hasMediaCharacteristic(.voiceOverTranslation) {
            characteristics.insert(.dubbedTranslation)
        }
        if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
            characteristics.insert(.forcedSubtitles)
        }
        if option.hasMediaCharacteristic(
            .transcribesSpokenDialogForAccessibility
        ) || option.hasMediaCharacteristic(
            .describesMusicAndSoundForAccessibility
        ) {
            characteristics.insert(.closedCaptions)
        }
        return characteristics
    }
}
