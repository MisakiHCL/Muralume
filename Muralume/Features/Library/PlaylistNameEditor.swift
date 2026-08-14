import SwiftUI

enum PlaylistNameEditorRequest: Identifiable {
    case create
    case rename(CustomPlaylist)

    var id: String {
        switch self {
        case .create:
            "create"
        case let .rename(playlist):
            "rename-\(playlist.id.rawValue.uuidString)"
        }
    }

    var initialName: String {
        switch self {
        case .create:
            ""
        case let .rename(playlist):
            playlist.name
        }
    }
}

private enum PlaylistNameEditorLayout {
    static let width: CGFloat = 360
    static let fieldHeight: CGFloat = 40
    static let borderWidth: CGFloat = 1
    static let focusedBorderWidth: CGFloat = 2
}

struct PlaylistNameEditor: View {
    let request: PlaylistNameEditorRequest
    let save: (String) throws -> Void
    let cancel: () -> Void
    let complete: () -> Void

    @State private var name: String
    @State private var validationKey: String?
    @FocusState private var isFocused: Bool

    init(
        request: PlaylistNameEditorRequest,
        save: @escaping (String) throws -> Void,
        cancel: @escaping () -> Void,
        complete: @escaping () -> Void
    ) {
        self.request = request
        self.save = save
        self.cancel = cancel
        self.complete = complete
        _name = State(initialValue: request.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.large) {
            Text(titleKey)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: MuralumeTheme.Spacing.small) {
                TextField("playlists.name.placeholder", text: $name)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .tint(MuralumeTheme.Colors.controlAccent)
                    .padding(.horizontal, MuralumeTheme.Spacing.medium)
                    .frame(height: PlaylistNameEditorLayout.fieldHeight)
                    .background(fieldBackground)
                    .accessibilityLabel(Text("playlists.name"))
                    .accessibilityIdentifier(
                        MuralumeAccessibilityIdentifier.playlistNameField
                    )

                if let validationKey {
                    Text(LocalizedStringKey(validationKey))
                        .font(.caption)
                        .foregroundStyle(MuralumeTheme.Colors.error)
                }
            }

            HStack(spacing: MuralumeTheme.Spacing.small) {
                Spacer()

                Button("action.cancel", action: cancel)
                    .buttonStyle(MuralumeSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Button(saveKey, action: submit)
                    .buttonStyle(MuralumeLightButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(MuralumeTheme.Colors.textPrimary)
        .padding(MuralumeTheme.Spacing.xLarge)
        .frame(width: PlaylistNameEditorLayout.width)
        .muralumePanel(cornerRadius: MuralumeTheme.Radius.xLarge)
        .task {
            await Task.yield()
            guard !Task.isCancelled else {
                return
            }
            isFocused = true
        }
        .onExitCommand(perform: cancel)
        .onChange(of: name) {
            validationKey = nil
        }
    }

    private var fieldBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: MuralumeTheme.Radius.medium,
            style: .continuous
        )

        return shape
            .fill(MuralumeTheme.Colors.controlFill)
            .overlay {
                shape.stroke(
                    isFocused
                        ? MuralumeTheme.Colors.textPrimary.opacity(0.72)
                        : MuralumeTheme.Colors.border,
                    lineWidth: isFocused
                        ? PlaylistNameEditorLayout.focusedBorderWidth
                        : PlaylistNameEditorLayout.borderWidth
                )
            }
    }

    private var titleKey: LocalizedStringKey {
        switch request {
        case .create:
            "playlists.new"
        case .rename:
            "playlists.rename"
        }
    }

    private var saveKey: LocalizedStringKey {
        switch request {
        case .create:
            "playlists.create"
        case .rename:
            "playlists.saveName"
        }
    }

    private func submit() {
        do {
            try save(name)
            complete()
        } catch let error as CustomPlaylistMutationError {
            validationKey = switch error {
            case .invalidName:
                "playlists.name.invalid"
            case .duplicateName:
                "playlists.name.duplicate"
            case .playlistLimitReached:
                "playlists.limit"
            case .entryLimitReached, .playlistNotFound:
                "playlists.error"
            }
        } catch {
            validationKey = "playlists.error"
        }
    }
}
