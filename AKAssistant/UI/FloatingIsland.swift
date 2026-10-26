import AppKit
import SwiftUI

/// The one floating popup, styled like the iPhone's Dynamic Island: a black shape that grows out of
/// the top of the screen (the notch, on Macs that have one) and shrinks back into it. It changes shape
/// with what's happening:
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
    private let presentation = IslandPresentation()
    private var windowSize = NSSize(width: 220, height: 44)
    private var screen: NSScreen?
    private var visible = false
    private var hideTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?

    /// How long the grow / shrink animation takes; the window waits this long before getting smaller.
    static let animationTime: Double = 0.45

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
            collapseAndHide()
            return
        }
        hideTask?.cancel()
        if panel == nil { panel = makePanel(state: state) }
        // The capsule lets clicks pass through; cards need the mouse for buttons and scrolling.
        panel?.ignoresMouseEvents = !mode.isInteractive
        if !visible {
            screen = NSScreen.main ?? NSScreen.screens.first
            measureNotch()
            presentation.expanded = false
            place()
            panel?.orderFrontRegardless()
            visible = true
            // Draw one frame collapsed into the notch, then grow out of it.
            Task { @MainActor [presentation] in
                try? await Task.sleep(for: .milliseconds(16))
                presentation.expanded = true
            }
        } else {
            presentation.expanded = true
        }
    }

    /// Reads this screen's real notch size, so the island folds into exactly that shape.
    private func measureNotch() {
        guard let screen else { return }
        let height = screen.safeAreaInsets.top
        if height > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            presentation.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: height)
        } else {
            presentation.notchSize = nil   // no notch: the island hangs from the menu bar instead
        }
    }

    /// Shrinks back into the top of the screen, then takes the window away.
    private func collapseAndHide() {
        guard visible, hideTask == nil || hideTask?.isCancelled == true else { return }
        presentation.expanded = false
        state?.setIslandHovering(false)   // the pointer can't be over a popup that's gone
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.animationTime))
            guard !Task.isCancelled, let self else { return }
            self.panel?.orderOut(nil)
            self.visible = false
            self.hideTask = nil
        }
    }

    /// SwiftUI reports the size it wants; the window follows, keeping its top edge pinned to the top
    /// of the screen and centred. Growing happens at once (so the animation has room); shrinking waits
    /// until the animation has finished, so nothing gets cut off mid-animation.
    fileprivate func contentDidResize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let folded = presentation.foldedSize
        let target = NSSize(width: ceil(max(size.width, folded.width)),
                            height: ceil(max(size.height, folded.height)))
        shrinkTask?.cancel()
        if target.width >= windowSize.width && target.height >= windowSize.height {
            windowSize = target
            place()
        } else {
            // Grow whichever side needs it now, shrink the rest later.
            windowSize = NSSize(width: max(target.width, windowSize.width), height: max(target.height, windowSize.height))
            place()
            shrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.animationTime))
                guard !Task.isCancelled, let self else { return }
                self.windowSize = target
                self.place()
            }
        }
    }

    private func place() {
        guard let panel, let frame = (screen ?? NSScreen.main)?.frame else { return }
        // Flush with the very top of the screen, over the menu bar, like the notch.
        let rect = NSRect(
            x: (frame.midX - windowSize.width / 2).rounded(),
            y: frame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
        guard rect != panel.frame else { return }
        panel.setFrame(rect, display: true)
        panel.invalidateShadow()
    }

    private func makePanel(state: AppState) -> NSPanel {
        let panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar        // above the menu bar, so it can sit over the notch area
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false         // a notch has no shadow; one would draw a grey halo around it
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = IslandView(presentation: presentation, onResize: { [weak self] size in self?.contentDidResize(size) })
            .environment(state)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []   // we size the window ourselves (top-anchored), not Auto Layout
        panel.contentView = host
        return panel
    }
}

/// A borderless panel that macOS won't nudge below the menu bar, so it can sit flush with the notch.
final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Animation state shared between the controller and the view.
@MainActor
@Observable
final class IslandPresentation {
    /// false = tucked into the top of the screen (notch-sized), true = grown out to its content.
    var expanded = false
    /// This Mac's camera notch, or nil on screens without one.
    var notchSize: CGSize?

    /// The little inward curves where the island meets the top edge, like the notch's own shoulders.
    static let shoulder: CGFloat = 8

    var hasNotch: Bool { notchSize != nil }
    /// Content starts below the notch so nothing hides behind the camera.
    var topInset: CGFloat { notchSize?.height ?? 0 }
    /// Size when folded away: exactly the notch (plus its shoulders), or a small tab without one.
    var foldedSize: CGSize {
        if let notch = notchSize { return CGSize(width: notch.width + 2 * Self.shoulder, height: notch.height) }
        return CGSize(width: 120 + 2 * Self.shoulder, height: 6)
    }
}

/// The island's outline: flush with the top edge, concave "shoulders" that flare into the screen edge
/// (like the MacBook notch), and rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat = IslandPresentation.shoulder

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 4, rect.height / 2)
        let r = max(0, min(bottomRadius, (rect.width - 2 * s) / 2, rect.height - s))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left shoulder curves in from the top edge.
        p.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s), control: CGPoint(x: rect.minX + s, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + s + r, y: rect.maxY), control: CGPoint(x: rect.minX + s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r), control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        // Right shoulder flares back out to the top edge.
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - s, y: rect.minY))
        p.closeSubpath()
        return p
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
    let presentation: IslandPresentation
    let onResize: @MainActor (CGSize) -> Void

    /// A bouncy-but-calm spring, close to the iPhone's Dynamic Island.
    private static let spring = Animation.spring(response: 0.45, dampingFraction: 0.78)

    var body: some View {
        let expanded = presentation.expanded
        let mode = state.islandMode
        let folded = presentation.foldedSize
        let shape = NotchShape(bottomRadius: !expanded ? (presentation.hasNotch ? 10 : 3) : (mode == .compact ? 18 : 24))

        content
            // Cards start below the notch; the capsule lays itself out around it (see CompactPill).
            .padding(.top, mode == .compact ? 0 : presentation.topInset)
            .padding(.horizontal, IslandPresentation.shoulder)   // keep content off the curved shoulders
            .fixedSize()                            // report the natural size; the window is resized to match
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onResize($0) }
            // Content fades and sharpens in as the island grows, and the reverse as it shrinks.
            .opacity(expanded ? 1 : 0)
            .blur(radius: expanded ? 0 : 6)
            .frame(width: expanded ? nil : folded.width, height: expanded ? nil : folded.height, alignment: .top)
            .background(Color.black, in: shape)   // pure black, the same as the notch
            .clipShape(shape)
            .onHover { state.setIslandHovering($0) }
            .animation(Self.spring, value: expanded)
            .animation(Self.spring, value: mode)
            .environment(presentation)
            .environment(\.colorScheme, .dark)     // white text and controls on the black island
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch state.islandMode {
        case .dictation:
            if let result = state.dictation {
                DictationCard(result: result).transition(.opacity)
            }
        case .answer:
            if let reply = state.reply {
                AnswerCard(reply: reply).id(reply.question).transition(.opacity)   // new question, fresh card state
            }
        case .compact, .hidden:
            CompactPill().transition(.opacity)
        }
    }
}

// MARK: - Capsule

struct CompactPill: View {
    @Environment(AppState.self) private var state
    @Environment(IslandPresentation.self) private var presentation

    /// Width of each side "wing" next to the notch.
    private static let wing: CGFloat = 78

    /// While talking (and until the final text is ready) the capsule grows to show what it hears.
    private var showsLiveText: Bool {
        guard !state.liveTranscript.isEmpty else { return false }
        return state.status == .recording || state.status == .transcribing
    }

    /// On a notched Mac the wings only fit an icon and the level bars, so words go on a line below.
    private var showsMessageLine: Bool {
        if inMeeting || state.isSpeaking { return true }
        switch state.status {
        case .done, .error: return true
        case .transcribing: return state.currentAction == .assistant || state.rewriteLabel != nil   // "Thinking…" / "Write as email…"
        default: return false
        }
    }

    var body: some View {
        let expanded = showsLiveText && !inMeeting
        Group {
            if let notch = presentation.notchSize {
                notchLayout(notch: notch, expanded: expanded)
            } else {
                plainLayout(expanded: expanded)
            }
        }
        .frame(width: expanded ? 440 : nil)
    }

    /// Notched Macs: icon on the left wing, activity on the right wing, the camera in the middle.
    private func notchLayout(notch: CGSize, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                icon
                    .frame(width: Self.wing, alignment: .leading)
                Spacer(minLength: notch.width)
                activity
                    .frame(width: Self.wing, alignment: .trailing)
            }
            .frame(height: notch.height)

            if showsMessageLine && !expanded {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            if expanded { liveText }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, (showsMessageLine || expanded) ? 10 : 0)
    }

    /// Macs without a notch: the classic capsule with the label in the middle.
    private func plainLayout(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if expanded { Spacer(minLength: 8) }
                activity
            }
            .frame(height: expanded ? 20 : 44)
            if expanded { liveText }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, expanded ? 12 : 0)
        .frame(minWidth: 200)
    }

    /// Level bars and timer while recording (or during a meeting).
    @ViewBuilder private var activity: some View {
        if inMeeting {
            HStack(spacing: 6) {
                LevelBars(level: state.meetings.level)
                if let started = state.meetings.startedAt { timer(from: started) }
            }
        } else if state.status == .recording {
            HStack(spacing: 6) {
                LevelBars(level: state.level)
                if let started = state.recordingStartedAt { timer(from: started) }
            }
        }
    }

    private func timer(from started: Date) -> some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            Text(Self.elapsed(from: started, to: context.date))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Keeps the newest words in view as you keep talking.
    private var liveText: some View {
        FittedScrollView(maxHeight: 132, followsNewContent: true) {
            Text(state.liveTranscript)
                .font(.system(size: 14))
                .lineSpacing(2)
                .foregroundStyle(state.status == .recording ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: state.liveTranscript)
        }
    }

    /// A meeting is recording and nothing else needs the capsule right now.
    private var inMeeting: Bool {
        state.meetings.isRecording && state.status == .idle
    }

    @ViewBuilder private var icon: some View {
        if inMeeting {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
        } else {
            statusIcon
        }
    }

    @ViewBuilder private var statusIcon: some View {
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
        if inMeeting { return "Meeting · press \(state.preferences.hotkey.shortTitle) to stop" }
        switch state.status {
        case .recording: return state.currentAction == .assistant ? "Ask me anything…" : "Listening…"
        case .transcribing:
            if let rewriting = state.rewriteLabel { return rewriting }
            return state.currentAction == .assistant ? "Thinking…" : "Transcribing…"
        case .done(let message): return message
        case .error(let message): return message
        case .idle: return state.isSpeaking ? "Speaking…" : "AK Assistant"
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        MeetingFormat.clock(now.timeIntervalSince(start))
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
