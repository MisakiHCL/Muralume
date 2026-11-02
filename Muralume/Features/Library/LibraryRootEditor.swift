import SwiftUI

struct LibraryRootEditor: View {
    let roots: [MediaLibraryRoot]
    let unavailableSources: [UnavailableMediaSource]
    let healthForRoot: (MediaLibraryRoot) -> MediaLibrarySourceHealth
    let healthForUnavailableSource: (UnavailableMediaSource) -> MediaLibrarySourceHealth
    let canRetryRoots: Bool
    let canRetryUnavailableSources: Bool
    let requestRetry: (MediaLibraryRoot) -> Void
    let requestUnavailableRetry: (UnavailableMediaSource) -> Void
    let requestRemoval: (MediaLibraryRoot) -> Void
    let requestRootReauthorization: (MediaLibraryRoot) -> Void
    let requestReauthorization: (UnavailableMediaSource) -> Void
    let requestUnavailableRemoval: (UnavailableMediaSource) -> Void

    @EnvironmentObject private var localization: AppLocalizationController

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MuralumeTheme.Spacing.small) {
                ForEach(roots) { root in
                    sourceRow(
                        identity: root.url.path,
                        name: root.displayName, path: root.url.path, kind: root.kind,
                        health: healthForRoot(root), canRetry: canRetryRoots,
                        retry: { requestRetry(root) },
                        reauthorize: { requestRootReauthorization(root) },
                        remove: { requestRemoval(root) },
                        removalKey: root.kind == .file ? "library.video.remove" : "library.folder.remove"
                    )
                }
                ForEach(unavailableSources) { source in
                    sourceRow(
                        identity: "unavailable." + source.id.rawValue,
                        name: source.displayName, path: source.lastKnownURL.path, kind: source.kind,
                        health: healthForUnavailableSource(source), canRetry: canRetryUnavailableSources,
                        retry: { requestUnavailableRetry(source) },
                        reauthorize: { requestReauthorization(source) },
                        remove: { requestUnavailableRemoval(source) },
                        removalKey: "library.source.unavailable.remove"
                    )
                }
            }
            .padding(.vertical, MuralumeTheme.Size.playlistContentInset)
        }
        .scrollIndicators(.visible)
        .accessibilityIdentifier(MuralumeAccessibilityIdentifier.sourceEditor)
    }

    private func sourceRow(
        identity: String, name: String, path: String, kind: MediaSourceKind,
        health: MediaLibrarySourceHealth, canRetry: Bool,
        retry: @escaping () -> Void, reauthorize: @escaping () -> Void,
        remove: @escaping () -> Void, removalKey: String
    ) -> some View {
        HStack(alignment: .top, spacing: MuralumeTheme.Spacing.small) {
            Image(systemName: kind == .file ? "film.fill" : "folder.fill")
                .font(.system(size: MuralumeTheme.Size.icon))
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .frame(width: MuralumeTheme.Size.iconLarge, height: MuralumeTheme.Size.control)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.xSmall) {
                HStack(spacing: MuralumeTheme.Spacing.small) {
                    Text(verbatim: name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: MuralumeTheme.Size.control, maxWidth: .infinity, alignment: .leading)
                        .help(Text(verbatim: path))
                    Label(LocalizedStringKey(health.status.localizedKey), systemImage: health.status.systemImage)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor(health.status))
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help(Text(verbatim: statusDescription(health)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: localization.localizedFormat(
                    "library.source.health.statusReason", name, statusDescription(health)
                )))
                .accessibilityIdentifier(MuralumeAccessibilityIdentifier.sourceHealthPrefix + identity)

                Text(verbatim: path)
                    .font(.caption)
                    .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: path))

                if let issue = health.issue {
                    Text(LocalizedStringKey(issue.localizedKey))
                        .font(.caption)
                        .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .help(Text(LocalizedStringKey(issue.localizedKey)))
                        // The status group already announces this reason.
                        .accessibilityHidden(true)
                }
                HStack(spacing: MuralumeTheme.Spacing.small) {
                    Text(verbatim: lastRefreshDescription(health))
                        .font(.caption2)
                        .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(Text(verbatim: lastRefreshDescription(health)))
                        .accessibilityIdentifier(MuralumeAccessibilityIdentifier.sourceLastRefreshPrefix + identity)
                    recoveryActions(
                        health: health, name: name, identity: identity, canRetry: canRetry,
                        retry: retry, reauthorize: reauthorize
                    )
                    sourceAction(
                        symbol: "minus.circle.fill", labelKey: removalKey,
                        action: remove
                    )
                    .foregroundStyle(MuralumeTheme.Colors.error)
                    .accessibilityValue(Text(verbatim: name))
                    .accessibilityHint(Text(verbatim: path))
                }
            }
        }
        .padding(MuralumeTheme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sourceRowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MuralumeAccessibilityIdentifier.sourceRowPrefix + identity)
    }

    @ViewBuilder
    private func recoveryActions(
        health: MediaLibrarySourceHealth, name: String, identity: String, canRetry: Bool,
        retry: @escaping () -> Void, reauthorize: @escaping () -> Void
    ) -> some View {
        if health.status.offersRetry {
            sourceAction(symbol: "arrow.clockwise", labelKey: "library.retry", action: retry)
                .disabled(!canRetry)
                .accessibilityValue(Text(verbatim: name))
                .accessibilityHint(Text(verbatim: statusDescription(health)))
                .accessibilityIdentifier(MuralumeAccessibilityIdentifier.sourceRetryPrefix + identity)
        }
        if health.status == .unavailable || health.issue == .authorizationRequired
            || health.issue == .permissionDenied || health.issue == .sourceMissing
            || (health.status == .failed && health.issue == .unknown) {
            sourceAction(
                symbol: "lock.open", labelKey: "library.sourceAccess.reauthorize",
                action: reauthorize
            )
            .disabled(!canRetry)
            .accessibilityValue(Text(verbatim: name))
            .accessibilityHint(Text(verbatim: statusDescription(health)))
            .accessibilityIdentifier(MuralumeAccessibilityIdentifier.sourceReauthorizePrefix + identity)
        }
    }

    private func sourceAction(
        symbol: String, labelKey: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: MuralumeTheme.Size.icon))
                .frame(width: MuralumeTheme.Size.control, height: MuralumeTheme.Size.control)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(Text(LocalizedStringKey(labelKey)))
        .accessibilityLabel(Text(LocalizedStringKey(labelKey)))
    }

    private func statusDescription(_ health: MediaLibrarySourceHealth) -> String {
        let status = localization.localized(health.status.localizedKey)
        guard let issue = health.issue else { return status }
        return localization.localizedFormat(
            "library.source.health.statusReason", status, localization.localized(issue.localizedKey)
        )
    }

    private func lastRefreshDescription(_ health: MediaLibrarySourceHealth) -> String {
        guard let date = health.lastSuccessfulRefresh else {
            return localization.localized("library.source.health.lastRefresh.unknown")
        }
        let formatted = date.formatted(
            Date.FormatStyle(date: .numeric, time: .shortened).locale(localization.locale)
        )
        return localization.localizedFormat("library.source.health.lastRefresh", formatted)
    }

    private func statusColor(_ status: MediaLibrarySourceHealthStatus) -> Color {
        switch status {
        case .ready: MuralumeTheme.Colors.controlAccent
        case .notScanned, .scanning: MuralumeTheme.Colors.textSecondary
        case .unavailable, .incomplete, .failed: MuralumeTheme.Colors.warning
        }
    }

    private var sourceRowBackground: some View {
        RoundedRectangle(cornerRadius: MuralumeTheme.Radius.medium, style: .continuous)
            .fill(MuralumeTheme.Colors.controlFill.opacity(0.52))
            .overlay {
                RoundedRectangle(cornerRadius: MuralumeTheme.Radius.medium, style: .continuous)
                    .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
            }
    }
}

private extension MediaLibrarySourceHealthStatus {
    var localizedKey: String {
        switch self {
        case .notScanned: "library.source.health.notScanned"
        case .scanning: "library.source.health.scanning"
        case .ready: "library.source.health.ready"
        case .unavailable: "library.source.health.unavailable"
        case .incomplete: "library.source.health.incomplete"
        case .failed: "library.source.health.failed"
        }
    }

    var systemImage: String {
        switch self {
        case .notScanned: "clock"
        case .scanning: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle"
        case .unavailable, .incomplete, .failed: "exclamationmark.triangle"
        }
    }

    var offersRetry: Bool {
        switch self {
        case .notScanned, .unavailable, .incomplete, .failed: true
        case .scanning, .ready: false
        }
    }
}

private extension MediaLibrarySourceHealthIssue {
    var localizedKey: String {
        switch self {
        case .authorizationRequired: "library.source.health.issue.authorizationRequired"
        case .permissionDenied: "library.source.health.issue.permissionDenied"
        case .temporarilyUnavailable: "library.source.health.issue.temporarilyUnavailable"
        case .sourceMissing: "library.source.health.issue.sourceMissing"
        case .timeLimitExceeded: "library.source.health.issue.timeLimitExceeded"
        case .memoryLimitExceeded: "library.source.health.issue.memoryLimitExceeded"
        case .unknown: "library.source.health.issue.unknown"
        }
    }
}
