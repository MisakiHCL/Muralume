import AppKit
import SwiftUI

struct PlayerSurfaceRepresentable<Surface>: NSViewRepresentable
where Surface: NSView, Surface: PlaybackRenderSurface {
    let makeSurface: @MainActor () -> Surface
    let onSurfaceCreated: @MainActor (Surface) -> Void

    func makeNSView(context: Context) -> Surface {
        let surface = makeSurface()
        onSurfaceCreated(surface)
        return surface
    }

    func updateNSView(_ nsView: Surface, context: Context) {}
}
