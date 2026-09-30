import AppKit
import SwiftUI

// The two expanded shapes of the floating popup (see FloatingIsland.swift).

private let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

/// Tall content scrolls instead of growing the popup past the screen.
private func maxTextHeight(fraction: CGFloat, cap: CGFloat) -> CGFloat {
    let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
    return max(160, min(cap, screenHeight * fraction))
}

private func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
}

// MARK: - AI answer

struct AnswerCard: View {
    @Environment(AppState.self) private var state
    let reply: AssistantReply

    @State private var questionExpanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            question
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider().opacity(0.6)

            FittedScrollView(
                maxHeight: maxTextHeight(fraction: 0.55, cap: 520),
                followsNewContent: reply.isStreaming
            ) {
                answer.padding(16)
            }

            Divider().opacity(0.6)

            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .frame(width: 480)
        .background(.regularMaterial, in: cardShape)
        .overlay(cardShape.strokeBorder(.white.opacity(0.12)))
        .clipShape(cardShape)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.purple.gradient)
            Text("AK Assistant")
                .font(.headline)
            statusBadge
            Spacer()
            CloseButton { state.closeAnswer() }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if reply.isStreaming && reply.answer.isEmpty {
            StatusBadge(title: "Thinking", systemImage: "ellipsis")
        } else if reply.isStreaming {
            StatusBadge(title: "Writing", systemImage: "pencil.line")
        } else if state.isSpeaking {
            StatusBadge(title: "Speaking", systemImage: "speaker.wave.2.fill")
        }
    }

    /// Your question, shown compactly. Long questions collapse to three lines.
    private var question: some View {
        let isLong = reply.question.count > 180
        return VStack(alignment: .leading, spacing: 4) {
            Label("You asked", systemImage: "mic.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if questionExpanded {
                FittedScrollView(maxHeight: 140) { questionText }
            } else {
                questionText.lineLimit(isLong ? 3 : nil)
            }
            if isLong {
                Button(questionExpanded ? "Show less" : "Show full question") {
                    withAnimation(.snappy) { questionExpanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var questionText: some View {
        Text(reply.question)
            .font(.callout)
            .foregroundStyle(.primary.opacity(0.85))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var answer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if reply.answer.isEmpty && reply.isStreaming {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            } else if !reply.answer.isEmpty {
                Text(markdown(reply.answer))
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = reply.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button {
                state.copyAnswer()
                showCopied()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(reply.answer.isEmpty)

            if state.isSpeaking {
                Button { state.stopSpeaking() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button { state.speakAgain() } label: {
                    Label("Read aloud", systemImage: "speaker.wave.2")
                }
                .disabled(reply.answer.isEmpty || reply.isStreaming)
            }

            Spacer()

            if !reply.isStreaming, !reply.answer.isEmpty {
                Text("\(wordCount(reply.answer)) words")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
            }

            Button { state.newConversation() } label: {
                Label("New chat", systemImage: "plus.bubble")
            }
            .help("Forget this conversation. The next question starts fresh.")
        }
        .buttonStyle(IslandButtonStyle())
    }

    private func showCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Renders simple markdown (bold, italics, code) if the model uses it.
    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Dictation transcript

struct DictationCard: View {
    @Environment(AppState.self) private var state
    let result: DictationResult

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            FittedScrollView(maxHeight: maxTextHeight(fraction: 0.4, cap: 320)) {
                Text(result.text)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Divider().opacity(0.6).padding(.top, 8)

            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .frame(width: 440)
        .background(.regularMaterial, in: cardShape)
        .overlay(cardShape.strokeBorder(.white.opacity(0.12)))
        .clipShape(cardShape)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: result.pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                .font(.system(size: 15))
                .foregroundStyle(result.pasted ? Color.green : Color.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if !result.pasted {
                    Text("Press ⌘V to paste it where you want")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(wordCount(result.text)) words")
                .font(.caption)
                .foregroundStyle(.tertiary)
            CloseButton { state.dismissDictation() }
        }
    }

    private var title: String {
        guard result.pasted else { return "Copied to clipboard" }
        if let app = result.appName { return "Pasted into \(app)" }
        return "Pasted"
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button {
                state.copyDictation()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Spacer()
            Text(state.isHoveringIsland ? "Stays open while the pointer is here" : "Closes automatically")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 6)
        }
        .buttonStyle(IslandButtonStyle())
    }
}

// MARK: - Building blocks

/// A scroll view that is exactly as tall as its content, up to `maxHeight`, then scrolls.
/// With `followsNewContent` it stays pinned to the newest text while it streams in,
/// unless you scroll up to read — then a "Latest" button takes you back down.
struct FittedScrollView<Content: View>: View {
    var maxHeight: CGFloat
    var followsNewContent = false
    @ViewBuilder var content: () -> Content

    @State private var contentHeight: CGFloat = 0
    @State private var following = true
    @State private var atBottom = true

    private var overflows: Bool { contentHeight > maxHeight + 0.5 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content()
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(overflows ? .automatic : .never)
            .scrollDisabled(!overflows)
            .frame(height: min(max(contentHeight, 1), maxHeight))
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
            } action: { _, isAtBottom in
                atBottom = isAtBottom
            }
            .onScrollPhaseChange { _, phase in
                // Only your own scrolling decides whether new text is followed.
                if phase == .idle { following = atBottom }
            }
            .onChange(of: contentHeight) {
                guard followsNewContent, following, overflows else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if followsNewContent, overflows, !following {
                    Button {
                        following = true
                        withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .clipShape(Capsule())
                    .padding(10)
                    .transition(.opacity)
                }
            }
        }
    }
}

struct StatusBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).symbolEffect(.variableColor.iterative)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close")
    }
}

/// Flat footer buttons with a soft highlight on hover.
struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering && isEnabled ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
