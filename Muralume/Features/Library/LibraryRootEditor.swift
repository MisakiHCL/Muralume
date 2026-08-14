import SwiftUI

struct LibraryRootEditor: View {
    let roots: [MediaLibraryRoot]
    let requestRemoval: (MediaLibraryRoot) -> Void

    var body: some View {
        VStack(alignment: .leading) {
            ScrollView {
                LazyVStack(spacing: MuralumeTheme.Spacing.small) {
                    ForEach(roots) { root in
                        rootRow(root)
                    }
                }
                .padding(
                    .vertical,
                    MuralumeTheme.Size.playlistContentInset
                )
            }
            .scrollIndicators(.visible)
        }
    }

    private func rootRow(_ root: MediaLibraryRoot) -> some View {
        HStack(spacing: MuralumeTheme.Spacing.medium) {
            Image(systemName: sourceIcon(for: root))
                .font(.system(size: MuralumeTheme.Size.icon))
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)

            VStack(
                alignment: .leading,
                spacing: MuralumeTheme.Spacing.xSmall
            ) {
                Text(verbatim: root.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(MuralumeTheme.Colors.textPrimary)
                    .lineLimit(1)

                Text(verbatim: root.url.path)
                    .font(.caption)
                    .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: MuralumeTheme.Spacing.small)

            Button {
                requestRemoval(root)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(
                        .system(
                            size: MuralumeTheme.Size.iconLarge,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(MuralumeTheme.Colors.error)
                    .frame(
                        width: MuralumeTheme.Size.control,
                        height: MuralumeTheme.Size.control
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help(Text(LocalizedStringKey(removalLabelKey(for: root))))
            .accessibilityLabel(
                Text(LocalizedStringKey(removalLabelKey(for: root)))
            )
        }
        .padding(MuralumeTheme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
            .fill(MuralumeTheme.Colors.controlFill.opacity(0.52))
            .overlay {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .stroke(MuralumeTheme.Colors.border, lineWidth: 1)
            }
        }
    }

    private func sourceIcon(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "film.fill"
        case .folder:
            "folder.fill"
        }
    }

    private func removalLabelKey(for root: MediaLibraryRoot) -> String {
        switch root.kind {
        case .file:
            "library.video.remove"
        case .folder:
            "library.folder.remove"
        }
    }
}
