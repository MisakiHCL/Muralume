import SwiftUI

struct LibrarySidebarEmptyState: View {
    let scanState: MediaLibraryScanState
    let sourceAccessState: MediaLibrarySourceAccessState
    let canRetrySourceAccess: Bool
    let retryScan: () -> Void
    let retrySourceAccess: () -> Void
    let reauthorizeMediaSources: () -> Void

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            Spacer(minLength: MuralumeTheme.Spacing.large)

            Image(systemName: iconName)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(titleKey))
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)

            detail
            recoveryActions

            Spacer(minLength: MuralumeTheme.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MuralumeTheme.Spacing.medium)
    }

    @ViewBuilder
    private var detail: some View {
        if sourceAccessIsUnavailable, scanState != .scanning {
            Text(LocalizedStringKey(sourceAccessDetailKey))
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        } else if let scanFailure {
            Text(LocalizedStringKey(scanFailure.localizedDetailKey))
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if sourceAccessIsUnavailable, scanState != .scanning {
            HStack(spacing: MuralumeTheme.Spacing.small) {
                Button("library.sourceAccess.retry") {
                    retrySourceAccess()
                }
                .buttonStyle(
                    MuralumeToolbarButtonStyle(
                        width: MuralumeTheme.Size.playlistRefreshActionWidth
                    )
                )
                .disabled(!canRetrySourceAccess)
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.retrySourceAccessButton
                )

                Button("library.sourceAccess.reauthorize") {
                    reauthorizeMediaSources()
                }
                .buttonStyle(
                    MuralumeToolbarButtonStyle(
                        width: MuralumeTheme.Size.playlistRefreshActionWidth
                    )
                )
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.reauthorizeSourcesButton
                )
            }
        } else if scanFailure != nil {
            Button("library.retry") {
                retryScan()
            }
            .buttonStyle(
                MuralumeToolbarButtonStyle(
                    width: MuralumeTheme.Size.playlistRefreshActionWidth
                )
            )
        }
    }

    private var sourceAccessIsUnavailable: Bool {
        sourceAccessState.hasUnavailableSources
    }

    private var sourceAccessTitleKey: String {
        sourceAccessState == .partiallyUnavailable
            ? "library.sourceAccess.partial"
            : "library.sourceAccess.unavailable.title"
    }

    private var sourceAccessDetailKey: String {
        sourceAccessState == .partiallyUnavailable
            ? "library.sourceAccess.partial.detail"
            : "library.sourceAccess.unavailable.detail"
    }

    private var scanFailure: MediaLibraryScanFailure? {
        guard case let .failed(failure) = scanState else {
            return nil
        }
        return failure
    }

    private var titleKey: String {
        if sourceAccessIsUnavailable, scanState != .scanning {
            return sourceAccessTitleKey
        }
        return scanFailure?.localizedTitleKey ?? "library.playlist.empty"
    }

    private var iconName: String {
        if sourceAccessIsUnavailable {
            return "externaldrive.badge.exclamationmark"
        }
        if scanFailure != nil {
            return "exclamationmark.triangle.fill"
        }
        if scanState == .scanning {
            return "magnifyingglass"
        }
        return "plus.rectangle.on.folder"
    }
}
