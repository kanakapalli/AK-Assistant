import AppKit
import SwiftUI

/// The one floating popup at the top of the screen. It changes shape with what's happening:
/// - a small capsule while you hold a hotkey ("Listening…", "Transcribing…", "Thinking…"),
/// - a card with your transcript after dictation,
/// - a card with your question and the AI's streaming answer.
///
/// It never takes focus, so the text field you're dictating into stays active, but the
/// card's buttons and text selection still work.
@MainActor
final class IslandController {
    private var panel: NSPanel?
    private weak var state: AppState?
    private var contentSize = NSSize(width: 220, height: 44)
    private var screen: NSScreen?
    private var visible = false

    /// Starts following `state.islandMode`: shows, hides and resizes the popup by itself.
    func attach(_ state: AppState) {
        self.state = state
        observe()
    }

    private func observe() {
        guard let state else { return }
        let mode = withObservationTracking {
            state.islandMode
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(mode)
    }

    private func apply(_ mode: IslandMode) {
        guard let state else { return }
        guard mode != .hidden else {
            if visible {
                panel?.orderOut(nil)
                visible = false
            }
            return
        }
        if panel == nil { panel = makePanel(state: state) }
        // The capsule lets clicks pass through; cards need the mouse for buttons and scrolling.
        panel?.ignoresMouseEvents = !mode.isInteractive
        if !visible {
            screen = NSScreen.main ?? NSScreen.screens.first
            place()
            panel?.orderFrontRegardless()
            visible = true
        }
    }

    /// SwiftUI reports its size; the window follows, keeping its top edge fixed and centred.
    fileprivate func contentDidResize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        contentSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        place()
    }

    private func place() {
        guard let panel, let frame = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let rect = NSRect(
            x: (frame.midX - contentSize.width / 2).rounded(),
            y: frame.maxY - contentSize.height - 10,
            width: contentSize.width,
            height: contentSize.height
        )
        guard rect != panel.frame else { return }
        panel.setFrame(rect, display: true)
        panel.invalidateShadow()
    }

    private func makePanel(state: AppState) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = IslandView(onResize: { [weak self] size in self?.contentDidResize(size) })
            .environment(state)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []   // we size the window ourselves (top-anchored), not Auto Layout
        panel.contentView = host
        return panel
    }
}

/// What the popup is showing right now.
enum IslandMode: Equatable {
    case hidden
    case compact     // capsule: listening / transcribing / thinking / short messages
    case dictation   // transcript card
    case answer      // question + AI answer card

    var isInteractive: Bool { self == .dictation || self == .answer }
}

// MARK: - Root view

struct IslandView: View {
    @Environment(AppState.self) private var state
    let onResize: @MainActor (CGSize) -> Void

    var body: some View {
        content
            .fixedSize()   // report the natural size; the window is resized to match
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onResize($0) }
            .onHover { state.setIslandHovering($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch state.islandMode {
        case .dictation:
            if let result = state.dictation { DictationCard(result: result) }
        case .answer:
            if let reply = state.reply { AnswerCard(reply: reply).id(reply.question) }   // new question, fresh card state
        case .compact, .hidden:
            CompactPill()
        }
    }
}

// MARK: - Capsule

struct CompactPill: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if state.status == .recording {
                LevelBars(level: state.level)
                if let started = state.recordingStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.elapsed(from: started, to: context.date))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 180)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }

    @ViewBuilder private var icon: some View {
        switch state.status {
        case .recording where state.currentAction == .assistant:
            Image(systemName: "sparkles").foregroundStyle(.purple)
        case .recording:
            Circle().fill(.red).frame(width: 10, height: 10)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            if state.isSpeaking {
                Image(systemName: "speaker.wave.2.fill").symbolEffect(.variableColor.iterative)
            } else {
                Image(systemName: "waveform")
            }
        }
    }

    private var label: String {
        switch state.status {
        case .recording: return state.currentAction == .assistant ? "Ask me anything…" : "Listening…"
        case .transcribing: return state.currentAction == .assistant ? "Thinking…" : "Transcribing…"
        case .done(let message): return message
        case .error(let message): return message
        case .idle: return state.isSpeaking ? "Speaking…" : "AK Assistant"
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let threshold = Float(i) / 5
                Capsule()
                    .fill(level > threshold ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(8 + i * 3))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
