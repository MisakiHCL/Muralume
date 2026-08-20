import SwiftUI

private enum VideoInformationValueFormatting {
    static let secondsPerMinute = 60
    static let minutesPerHour = 60
    static let bitsPerKilobit = 1_000.0
    static let bitsPerMegabit = 1_000_000.0
    static let maximumIntegerDuration = TimeInterval(Int.max / 2)
}

struct VideoInformationPanel: View {
    private enum LoadingState: Equatable {
        case loading
        case loaded(VideoInformation)
        case failed
    }

    let item: LibraryMediaItem
    let loader: any VideoInformationLoading

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @EnvironmentObject private var localization: AppLocalizationController
    @State private var loadingState: LoadingState = .loading
    @State private var reloadRequest: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(MuralumeTheme.Colors.border)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: MuralumeTheme.Size.videoInformationPanelWidth)
        .frame(
            minHeight: MuralumeTheme.Size.videoInformationPanelMinimumHeight
        )
        .background {
            panelBackground
        }
        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
        .task(id: reloadRequest) {
            await loadInformation()
        }
    }

    private var header: some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            Text("videoInfo.title")
                .font(.headline)

            Spacer(minLength: MuralumeTheme.Spacing.large)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(
                        .system(
                            size: MuralumeTheme.Size.icon,
                            weight: .semibold
                        )
                    )
                    .frame(
                        width: MuralumeTheme.Size.compactControl,
                        height: MuralumeTheme.Size.compactControl
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            .contentShape(Rectangle())
            .help(Text("action.close"))
            .accessibilityLabel(Text("action.close"))
        }
        .padding(MuralumeTheme.Spacing.large)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            MuralumeTheme.Colors.panel
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    MuralumeTheme.Colors.panel.opacity(
                        MuralumeTheme.Glass.videoInformationTintOpacity
                    )
                )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadingState {
        case .loading:
            VStack(spacing: MuralumeTheme.Spacing.medium) {
                ProgressView()
                    .controlSize(.regular)
                Text("videoInfo.loading")
                    .font(.callout)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
            }
        case let .loaded(information):
            informationContent(information)
        case .failed:
            VStack(spacing: MuralumeTheme.Spacing.large) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: MuralumeTheme.Size.iconLarge))
                    .foregroundStyle(MuralumeTheme.Colors.warning)
                    .accessibilityHidden(true)
                Text("videoInfo.error")
                    .font(.callout)
                    .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                Button("library.retry") {
                    reloadRequest &+= 1
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(MuralumeTheme.Spacing.xLarge)
        }
    }

    private func informationContent(
        _ information: VideoInformation
    ) -> some View {
        ScrollView {
            Grid(
                alignment: .leading,
                horizontalSpacing: MuralumeTheme.Spacing.xLarge,
                verticalSpacing: MuralumeTheme.Spacing.medium
            ) {
                informationRow(
                    "videoInfo.fileName",
                    value: item.displayName
                )
                informationRow(
                    "videoInfo.container",
                    value: information.container ?? unknownValue
                )
                informationRow(
                    "videoInfo.duration",
                    value: durationText(information.duration)
                )
                informationRow(
                    "videoInfo.videoCodec",
                    value: codecText(information.videoCodecs)
                )
                informationRow(
                    "videoInfo.resolution",
                    value: resolutionText(information.resolution)
                )
                informationRow(
                    "videoInfo.aspectRatio",
                    value: aspectRatioText(information.resolution)
                )
                informationRow(
                    "videoInfo.frameRate",
                    value: frameRateText(information.frameRate)
                )
                informationRow(
                    "videoInfo.videoBitRate",
                    value: bitRateText(information.videoBitRate)
                )
                informationRow(
                    "videoInfo.dynamicRange",
                    value: dynamicRangeText(information.dynamicRange)
                )
                informationRow(
                    "videoInfo.colorSpace",
                    value: information.colorSpace ?? unknownValue
                )
                informationRow(
                    "videoInfo.audioCodec",
                    value: audioCodecText(information)
                )
                informationRow(
                    "videoInfo.audioTrackCount",
                    value: countText(information.audioTrackCount)
                )
                informationRow(
                    "videoInfo.subtitleTrackCount",
                    value: countText(information.subtitleTrackCount)
                )
                informationRow(
                    "videoInfo.fileSize",
                    value: fileSizeText(
                        information.fileSize ?? item.fileSize
                    )
                )
            }
            .padding(MuralumeTheme.Spacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private func informationRow(
        _ labelKey: LocalizedStringKey,
        value: String
    ) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(labelKey)
                .font(.callout)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .frame(
                    width: MuralumeTheme.Size.videoInformationLabelWidth,
                    alignment: .leading
                )

            Text(verbatim: value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func loadInformation() async {
        loadingState = .loading
        do {
            let information = try await loader.information(
                for: ResolvedMediaSource(
                    url: item.url,
                    displayName: item.displayName
                )
            )
            try Task.checkCancellation()
            loadingState = .loaded(information)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }
            loadingState = .failed
        }
    }

    private var unknownValue: String {
        localization.localized("videoInfo.value.unknown")
    }

    private func codecText(_ codecs: [String]) -> String {
        codecs.isEmpty ? unknownValue : codecs.joined(separator: ", ")
    }

    private func audioCodecText(_ information: VideoInformation) -> String {
        guard information.audioTrackCount > 0 else {
            return localization.localized("videoInfo.value.none")
        }
        return codecText(information.audioCodecs)
    }

    private func resolutionText(_ resolution: VideoResolution?) -> String {
        guard let resolution else {
            return unknownValue
        }
        return localization.localizedFormat(
            "videoInfo.value.resolution",
            resolution.width,
            resolution.height
        )
    }

    private func frameRateText(_ frameRate: Double?) -> String {
        guard let frameRate else {
            return unknownValue
        }
        let formattedRate = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0 ... 2))
            .locale(localization.locale)
            .format(frameRate)
        return localization.localizedFormat(
            "videoInfo.value.frameRate",
            formattedRate
        )
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration,
              duration.isFinite,
              duration >= 0,
              duration <= VideoInformationValueFormatting
                .maximumIntegerDuration else {
            return unknownValue
        }
        let totalSeconds = Int(duration.rounded())
        let secondsPerHour = VideoInformationValueFormatting
            .secondsPerMinute
            * VideoInformationValueFormatting.minutesPerHour
        let hours = totalSeconds / secondsPerHour
        let minutes = (totalSeconds % secondsPerHour)
            / VideoInformationValueFormatting.secondsPerMinute
        let seconds = totalSeconds
            % VideoInformationValueFormatting.secondsPerMinute
        if hours > 0 {
            return localization.localizedFormat(
                "videoInfo.value.duration.hours",
                hours,
                minutes,
                seconds
            )
        }
        return localization.localizedFormat(
            "videoInfo.value.duration.minutes",
            minutes,
            seconds
        )
    }

    private func aspectRatioText(_ resolution: VideoResolution?) -> String {
        guard let aspectRatio = resolution?.aspectRatio else {
            return unknownValue
        }
        return localization.localizedFormat(
            "videoInfo.value.aspectRatio",
            aspectRatio.width,
            aspectRatio.height
        )
    }

    private func bitRateText(_ bitRate: Double?) -> String {
        guard let bitRate, bitRate.isFinite, bitRate > 0 else {
            return unknownValue
        }
        let unitDivisor: Double
        let formatKey: String
        if bitRate >= VideoInformationValueFormatting.bitsPerMegabit {
            unitDivisor = VideoInformationValueFormatting.bitsPerMegabit
            formatKey = "videoInfo.value.megabitsPerSecond"
        } else {
            unitDivisor = VideoInformationValueFormatting.bitsPerKilobit
            formatKey = "videoInfo.value.kilobitsPerSecond"
        }
        let formattedRate = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0 ... 2))
            .locale(localization.locale)
            .format(bitRate / unitDivisor)
        return localization.localizedFormat(formatKey, formattedRate)
    }

    private func dynamicRangeText(_ dynamicRange: VideoDynamicRange) -> String {
        let key = switch dynamicRange {
        case .unknown:
            "videoInfo.value.unknown"
        case .sdr:
            "videoInfo.value.sdr"
        case .hdr10:
            "videoInfo.value.hdr10"
        case .hlg:
            "videoInfo.value.hlg"
        case .dolbyVision:
            "videoInfo.value.dolbyVision"
        }
        return localization.localized(key)
    }

    private func countText(_ count: Int) -> String {
        IntegerFormatStyle<Int>.number
            .locale(localization.locale)
            .format(max(count, 0))
    }

    private func fileSizeText(_ fileSize: Int64) -> String {
        ByteCountFormatStyle(
            style: .file,
            allowedUnits: .all,
            spellsOutZero: false,
            includesActualByteCount: true
        )
        .locale(localization.locale)
        .format(max(fileSize, 0))
    }
}
