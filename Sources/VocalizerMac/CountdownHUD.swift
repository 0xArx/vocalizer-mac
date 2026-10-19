// Centre-of-screen countdown while videos hold their picture for Vocalizer's delay (Best ~7 s, Clean ~2 s),
// styled like the macOS volume HUD. Click-through, above full-screen video, fades in and out.
import AppKit
import SwiftUI

@MainActor
final class CountdownHUD {
    private var panel: NSPanel?
    private var visible = false

    func update(model: AppModel) {
        let enabled = UserDefaults.standard.object(forKey: "screenCountdown") as? Bool ?? true
        let show = enabled && model.enabled && (model.preparing != nil || model.catchUpSeconds != nil)
        if show && !visible { present(model: model) } else if !show && visible { dismiss() }
    }

    private func present(model: AppModel) {
        let size = NSSize(width: 190, height: 190)
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: CountdownView(model: model))
            panel = p
            return p
        }()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        visible = true
    }

    private func dismiss() {
        visible = false
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; p.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if !self.visible { p.orderOut(nil) } }
        }
    }
}

struct CountdownView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.animation) { _ in
            VStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 7)
                    if model.preparing != nil {
                        ProgressView().controlSize(.large)
                    } else {
                        Circle()
                            .trim(from: 0, to: model.catchUpProgress ?? 1)
                            .stroke(LinearGradient(colors: [Color(red: 0.55, green: 0.24, blue: 1.0), Color(red: 0.80, green: 0.55, blue: 1.0)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(model.catchUpSeconds ?? 0)")
                            .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }
                .frame(width: 84, height: 84)
                Text(model.preparing != nil ? "Preparing Best" : "Video starts soon")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(width: 190, height: 190)
            .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)))
        }
    }
}

/// The frosted HUD material (NSVisualEffectView).
private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
