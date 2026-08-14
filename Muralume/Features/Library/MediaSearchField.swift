import AppKit
import SwiftUI

struct MediaSearchField: View {
    @Binding var query: String
    let focusRequest: UInt64
    let accessibilityLabel: String
    let consumeFocusRequest: (UInt64) -> Void
    let dismissSidebar: () -> Void

    @FocusState private var isFocused: Bool
    @State private var shouldSuppressInitialAutomaticFocus = true

    var body: some View {
        HStack(spacing: MuralumeTheme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                .accessibilityHidden(true)

            TextField("library.search.placeholder", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .accessibilityIdentifier(
                    MuralumeAccessibilityIdentifier.librarySearchField
                )

            if !query.isEmpty {
                Button {
                    query = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MuralumeTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help(Text("library.search.clear"))
                .accessibilityLabel(Text("library.search.clear"))
            }
        }
        .padding(.horizontal, MuralumeTheme.Spacing.small)
        .frame(height: MuralumeTheme.Size.searchFieldHeight)
        .background {
            RoundedRectangle(
                cornerRadius: MuralumeTheme.Radius.medium,
                style: .continuous
            )
            .fill(MuralumeTheme.Colors.controlFill.opacity(0.72))
            .overlay {
                RoundedRectangle(
                    cornerRadius: MuralumeTheme.Radius.medium,
                    style: .continuous
                )
                .stroke(
                    isFocused
                        ? MuralumeTheme.Colors.borderStrong
                        : MuralumeTheme.Colors.border,
                    lineWidth: 1
                )
            }
        }
        .task(id: focusRequest) {
            // Cmd-F can change the route and create this field in the same
            // update, so onChange alone would miss the initial focus token.
            guard focusRequest > 0 else {
                return
            }
            shouldSuppressInitialAutomaticFocus = false
            let request = focusRequest
            await Task.yield()
            guard !Task.isCancelled else {
                return
            }
            isFocused = true
            consumeFocusRequest(request)
        }
        .onAppear {
            suppressInitialAutomaticFocusIfNeeded(in: NSApp.keyWindow)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSWindow.didBecomeKeyNotification
            )
        ) { notification in
            suppressInitialAutomaticFocusIfNeeded(
                in: notification.object as? NSWindow
            )
        }
        .onChange(of: focusRequest) {
            if focusRequest > 0 {
                shouldSuppressInitialAutomaticFocus = false
            }
        }
        .onExitCommand {
            if !query.isEmpty {
                query = ""
                isFocused = true
            } else if isFocused {
                isFocused = false
            } else {
                dismissSidebar()
            }
        }
    }

    private func suppressInitialAutomaticFocusIfNeeded(
        in window: NSWindow?
    ) {
        guard let window,
              window.isKeyWindow,
              window.identifier?.rawValue
                == AppConfiguration.mainWindowSceneID,
              shouldSuppressInitialAutomaticFocus,
              focusRequest == 0 else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  window.isKeyWindow,
                  shouldSuppressInitialAutomaticFocus,
                  focusRequest == 0 else {
                return
            }
            isFocused = false
            window.makeFirstResponder(nil)
            shouldSuppressInitialAutomaticFocus = false
        }
    }
}

struct LibrarySearchEmptyState: View {
    let clear: () -> Void

    var body: some View {
        VStack(spacing: MuralumeTheme.Spacing.medium) {
            Spacer(minLength: MuralumeTheme.Spacing.large)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(MuralumeTheme.Colors.controlAccent)
                .accessibilityHidden(true)
            Text("library.search.noResults")
                .font(.body.weight(.semibold))
            Text("library.search.noResults.detail")
                .font(.caption)
                .foregroundStyle(MuralumeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("library.search.clear", action: clear)
                .buttonStyle(.link)
            Spacer(minLength: MuralumeTheme.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MuralumeTheme.Spacing.medium)
    }
}
