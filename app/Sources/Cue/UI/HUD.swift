import AppKit
import SwiftUI

/// Small toast near the bottom of the screen confirming what was applied.
final class HUDController {
    private let panel: NSPanel
    private let host: NSHostingView<HUDView>
    private var hideWork: DispatchWorkItem?
    private var generation = 0
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        host = NSHostingView(rootView: HUDView(text: "", isError: false, theme: Theme.all[0]))
        panel.contentView = host
    }

    func show(_ text: String, isError: Bool) {
        host.rootView = HUDView(text: text, isError: isError, theme: Theme.resolve(model.prefs))
        let size = host.fittingSize
        let width = min(max(size.width, 220), 640)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: vf.midX - width / 2, y: vf.minY + 70, width: width, height: max(size.height, 40)), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        hideWork?.cancel()
        generation += 1
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.panel.animator().alphaValue = 0
            }, completionHandler: { if gen == self.generation { self.panel.orderOut(nil) } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4 : 1.8), execute: work)
    }
}

struct HUDView: View {
    let text: String
    let isError: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? Color(hex: "#FF8A8E") : theme.accent)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: 640)
        .background(
            ZStack { VisualEffect(material: theme.material); theme.background.opacity(0.75) }
        )
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}
