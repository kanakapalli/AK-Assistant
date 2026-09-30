# AK Assistant

Hold a key, speak, let go: AK Assistant turns your speech into text and pastes it into whatever text field has focus on your Mac. Hold a second key to ask a local AI a question and get the answer on screen and read aloud. Everything runs **entirely on-device** with open-source models from Hugging Face. Your audio and questions never leave the Mac.

- **Push-to-talk:** hold the hotkey to record, release to transcribe and paste. Press **Esc** while holding to cancel.
- **AI assistant:** hold the AI hotkey (default Right Command), ask anything, release. A local chat model answers in a floating panel and, if you like, a local voice reads it aloud. Follow-ups within 5 minutes continue the conversation.
- **Works in any app:** dictation runs in the background. AK Assistant doesn't need to be in front.
- **Dock and menu bar:** open the app from the Dock or the menu bar icon to see your history, manage models and change settings.
- **History:** every dictation is saved locally with the time, the app it went into, and the model used. Search, copy, export or delete it.
- **Onboarding:** first launch walks you through permissions, the speech model, the AI and voice models, how answers come back, and both hotkeys.

## Requirements

| | |
| --- | --- |
| Mac | Apple Silicon (M1 or newer) |
| macOS | 15 Sequoia or newer (the voice engine needs it) |
| Xcode | 26 or newer (the MLX package needs Swift 6.2) |
| Memory | 16 GB recommended with the AI assistant on; on 8 GB pick Qwen3 1.7B and Whisper Small |
| Disk | 150 MB – 650 MB per speech model, 1–5 GB per AI model, 1–2 GB per voice |

## Getting started

This is a standard Xcode project, like one made with File → New → Project → macOS → App.

1. Double-click **`AKAssistant.xcodeproj`** in the `AK Assistant` folder on your Desktop.
2. Xcode downloads the Swift packages: Argmax (WhisperKit + TTSKit), FluidAudio, KeyboardShortcuts, MLX Swift LM, Swift Hugging Face and Swift Transformers. Watch the progress at the top of the window; the first time takes several minutes.
   - If Xcode asks to **Trust & Enable** the `MLXHuggingFaceMacros` macros, allow it. The app uses them to load AI models.
   - If Xcode says the **Metal Toolchain** is missing (MLX needs it), install it from Xcode → Settings → Components.
3. Click the **AKAssistant** project in the left sidebar → **AKAssistant** target → **Signing & Capabilities**, and pick your Team (your Apple ID works for running locally).
4. Press **⌘R** to build and run. Onboarding opens on first launch.

**Where things are set in Xcode** (useful while learning):

| What | Where in Xcode |
| --- | --- |
| App name, bundle ID, version | Target → **General** |
| Microphone permission text | Target → **Info** (or Build Settings → search "Microphone") |
| Entitlements, signing, hardened runtime | Target → **Signing & Capabilities** |
| Swift packages | Project → **Package Dependencies** |
| App icon, accent colour | `Assets.xcassets` |

The project uses Xcode 16 folder syncing: any file you add to the `AKAssistant` folder, in Finder or in Xcode, becomes part of the app automatically.

> **Accessibility permission and rebuilds:** macOS ties the Accessibility grant to the app's code signature. If the hotkey stops working after a rebuild, remove AK Assistant from System Settings → Privacy & Security → Accessibility and add it again. Keeping the same signing team avoids most of this.

## Models

All five are Core ML builds that run on the Neural Engine. They download during onboarding (or later from the **Models** tab) into `~/Library/Application Support/AK Assistant/Models`.

| Model | Hugging Face source | Size | Languages | Best for |
| --- | --- | --- | --- | --- |
| **Whisper Large v3 Turbo** (default) | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) `openai_whisper-large-v3-v20240930_turbo_632MB` | 632 MB | 99 | Best accuracy; Indian English, Hindi, mixed languages |
| Parakeet TDT 0.6B v3 | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | ~600 MB | 25 European + Japanese | Fastest; built-in punctuation |
| Distil-Whisper Large v3 Turbo | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) `distil-whisper_distil-large-v3_turbo_600MB` | 600 MB | English | Lower-latency English |
| Whisper Small | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) `openai_whisper-small_216MB` | 216 MB | 99 | 8 GB Macs, quick setup |
| Whisper Base (English) | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) `openai_whisper-base.en` | ~150 MB | English | Smallest; low-power fallback |

Parakeet is managed by FluidAudio and is cached in `~/Library/Application Support/FluidAudio/Models`.

To add a model, append a `SpeechModel` to `ModelCatalog.all` in `AKAssistant/Models/ModelCatalog.swift`. Any WhisperKit variant folder from the `argmaxinc/whisperkit-coreml` repo works.

### AI assistant models

Chat models run with Apple's [MLX](https://github.com/ml-explore/mlx-swift-lm) on the GPU. They download into the standard Hugging Face cache, `~/.cache/huggingface/hub`.

| Model | Hugging Face repo | Size | Best for |
| --- | --- | --- | --- |
| **Qwen3 4B** (default) | [mlx-community/Qwen3-4B-4bit](https://huggingface.co/mlx-community/Qwen3-4B-4bit) | 2.3 GB | Smart, fast, multilingual |
| Gemma 4 E4B | [mlx-community/gemma-4-e4b-it-4bit](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit) | 5.2 GB | Highest quality (16 GB Macs) |
| Gemma 4 E2B | [mlx-community/gemma-4-e2b-it-4bit](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit) | 3.6 GB | Balance of quality and speed |
| Llama 3.2 3B | [mlx-community/Llama-3.2-3B-Instruct-4bit](https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit) | 1.8 GB | Quick everyday answers |
| Qwen3 1.7B | [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) | 1.0 GB | Smallest; 8 GB Macs |

Qwen3's "thinking" mode is turned off so answers come back quickly.

### Voice models

Answers are spoken by [Qwen3-TTS](https://huggingface.co/argmaxinc/ttskit-coreml) through Argmax's TTSKit (Core ML). Files go in `~/Library/Application Support/AK Assistant/Models/Voice`.

| Model | Size | Notes |
| --- | --- | --- |
| **Qwen3 TTS 0.6B** (default) | ~1 GB | Natural voice, low delay |
| Qwen3 TTS 1.7B | ~2.2 GB | Richer voice, a bit slower |

Nine built-in speakers (Ryan, Aiden, Eric, Dylan, Serena, Vivian, Ono Anna, Sohee, Uncle Fu), chosen in Settings → AI assistant. The voice speaks 10 languages (English, Chinese, Japanese, Korean, German, French, Russian, Portuguese, Spanish, Italian); other languages fall back to English.

## How it works

```
Hold hotkey ─▶ Recorder ─▶ STT engine ─▶ Post-process ─▶ Text inserter ─▶ focused text field
 (Right ⌥)     16 kHz mono   WhisperKit /    fillers,        clipboard + ⌘V,
               in memory     FluidAudio      spacing          clipboard restored
                                  ▲               │
                           Model Manager     History (SwiftData)
                           (Hugging Face)
```

1. **Hotkey** (`Hotkey/HotkeyManager.swift`): watches key down and key up anywhere in the system. Modifier-only keys (Right Option, Right Command, Right Control, Fn) use `NSEvent` flagsChanged monitors. Custom combos use [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).
2. **Recorder** (`Audio/AudioRecorder.swift`): `AVAudioEngine` converts the mic to 16 kHz mono Float32 in memory. Nothing is written to disk.
3. **Transcription** (`Transcription/`): one `TranscriptionEngine` protocol with two backends, [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) and [FluidAudio](https://github.com/FluidInference/FluidAudio). The model starts loading as soon as you press the key, stays loaded between dictations, and unloads after 10 idle minutes.
4. **Post-process** (`Support/PostProcessor.swift`): strips Whisper artefacts like `[BLANK_AUDIO]`, removes fillers (optional), fixes spacing and capitalisation.
5. **Insert** (`Insertion/TextInserter.swift`): saves your clipboard, pastes with a synthetic ⌘V, then restores the clipboard. If nothing has focus, the text is left on the clipboard and the pill says "Copied to clipboard".
6. **History** (`History/DictationRecord.swift`): SwiftData store with retention settings (forever, 30 days, 7 days, off) and CSV/text export.

Clips shorter than 0.3 s or near-silent are skipped, so Whisper doesn't invent text from silence. Recordings stop automatically after 2 minutes.

## Project layout

```
AK Assistant/
├── AKAssistant.xcodeproj       Open this in Xcode
├── README.md
└── AKAssistant/                All app code (synced with Xcode)
    ├── AKAssistantApp.swift    App entry point (@main): main window + menu bar icon
    ├── Assets.xcassets         App icon and accent colour
    ├── AKAssistant.entitlements  Microphone access under the hardened runtime
    ├── App/                    AppState (the dictation pipeline), Preferences
    ├── Audio/                  AudioRecorder
    ├── Hotkey/                 HotkeyManager, hotkey choices
    ├── Transcription/          Engine protocol, WhisperKit + Parakeet engines, TranscriptionService
    ├── Assistant/              LLMService (local chat model), SpeechService (voice)
    ├── Models/                 ModelCatalog (speech models), AssistantCatalog (AI + voice models), ModelManager (download/delete)
    ├── Insertion/              TextInserter (paste + clipboard restore, typing fallback)
    ├── History/                DictationRecord (SwiftData), pruning, export
    ├── Support/                Permissions, sounds, post-processing
    └── UI/                     Main window, History, Models, Settings, Onboarding, menu bar, recording pill
```

A good reading order for learning: `AKAssistantApp.swift` → `App/AppState.swift` (follow `beginRecording` and `endRecording`) → `Hotkey/` → `Audio/` → `Transcription/` → `Insertion/` → `UI/`.

### The AI assistant flow

```
Hold AI key ─▶ Recorder ─▶ Whisper ─▶ LLMService (MLX chat model) ─▶ answer panel (streams in)
                                              │                            │
                                      short conversation              SpeechService (Qwen3-TTS)
                                      (resets after 5 min)            reads it aloud
```

- `Assistant/LLMService.swift` loads the chat model with `#huggingFaceLoadModelContainer` and keeps a `ChatSession`, so follow-up questions have context. It unloads after 10 idle minutes.
- `Assistant/SpeechService.swift` loads Qwen3-TTS with `TTSKit` and plays the answer sentence by sentence as it's generated.
- `UI/AnswerPanel.swift` is the floating panel: copy, speak again or stop, and "New chat" to forget the conversation.
- Answers are saved in History with the question.
- Pressing a hotkey while an answer is being spoken stops the voice, so the mic only hears you.

## Modern SwiftUI patterns used

The app uses current SwiftUI and Swift APIs (macOS 14+), so you're learning today's patterns:

| Pattern | Where | What it replaces |
| --- | --- | --- |
| `@Observable` classes | `AppState`, `Preferences`, `ModelManager` | `ObservableObject` + `@Published` |
| `@State` holding an observable model | `AKAssistantApp` | `@StateObject` |
| `.environment(object)` + `@Environment(Type.self)` | App entry, every view | `.environmentObject` + `@EnvironmentObject` |
| `@Bindable` for `$bindings` | `SettingsView`, `HotkeyPicker` | `$object.property` on `@ObservedObject` |
| `withObservationTracking` | `AppState.observePreferences()` | Combine `$property.sink` |
| SwiftData `@Model` + `@Query` | `DictationRecord`, `HistoryView`, menu bar | Core Data |
| `.task { … Task.sleep … }` loops | Settings and onboarding permission checks | `Timer.publish` + `.onReceive` |
| `MenuBarExtra`, `Window`, `NavigationSplitView`, `ContentUnavailableView` | UI | AppKit status items and windows |

AppKit is used only where SwiftUI has no API: the floating "Listening…" pill (`NSPanel`), watching keys in other apps (`NSEvent` monitors), and pasting (`NSPasteboard` plus a synthetic ⌘V).

The target builds in the Swift 5 language mode, so the third-party packages don't trigger strict-concurrency errors. Switch to Swift 6 later under Build Settings → Swift Language Version.

## Permissions

| Permission | Why |
| --- | --- |
| Microphone | Recording while the hotkey is held |
| Accessibility | Seeing the hotkey in other apps and pasting into them |
| Network | Only to download models from Hugging Face. Questions and answers stay on the Mac. |

The app isn't sandboxed, because the App Sandbox blocks synthetic key events into other apps. Distribute it outside the Mac App Store with a Developer ID certificate and notarization.

## Settings

- **Push-to-talk key:** Right Option (default), Right Command, Right Control, Fn/Globe, or any custom shortcut.
- **Language:** auto-detect, or pin one (English, Hindi, Telugu, Tamil, Kannada, Marathi, Bengali, Spanish, French, German, Japanese, Chinese). Parakeet ignores this setting.
- Remove filler words, restore the clipboard after pasting, start/stop sounds, launch at login.
- History retention and permission status.

## Status and next steps

Dictation builds and runs. The AI assistant (chat model + voice) is new and hasn't been compiled yet, so expect a round of small fixes on the first build, mostly where the MLX and TTSKit APIs meet the app.

- [x] Dictation, history, onboarding, app icon
- [ ] First build and fix-ups for the AI assistant
- [ ] Per-app paste overrides and a typing fallback toggle (`TextInserter.typeText` is already in place)
- [ ] Custom vocabulary (names, jargon) passed to Whisper as a prompt
- [ ] Voice-activity detection to trim leading and trailing silence
- [ ] "Paste the answer" option for the assistant
- [ ] Developer ID signing, notarization, Sparkle updates, DMG
- [ ] Later: tools (calendar, files, web) and commands, toward the full local assistant

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Hotkey does nothing | Check Accessibility in Settings → Permissions. After a rebuild, remove the app from Accessibility and add it again. |
| Fn opens the emoji picker | System Settings → Keyboard → "Press 🌐 key to" → Do Nothing |
| Text isn't pasted in one app | Some fields block synthetic paste (password fields, some terminals). The text is still on the clipboard. |
| First dictation is slow | Core ML compiles the model the first time it loads. Onboarding does this for you; switching models repeats it once. |
| "Download … first" | Download the selected model in the Models tab. |
| AI hotkey does nothing | Check Settings → AI assistant: the key isn't "Off", and the AI model shows **Ready** in Models. |
| Answers aren't spoken | Pick "Show and speak" or "Speak only", and download a voice in Models → Voice. |
| First AI answer is slow | The chat model loads when you first press the AI key (a few seconds). Later questions are fast until it unloads after 10 idle minutes. |

## Credits

- [WhisperKit and TTSKit](https://github.com/argmaxinc/argmax-oss-swift) by Argmax (MIT)
- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) by Apple (MIT)
- [Swift Hugging Face](https://github.com/huggingface/swift-huggingface) and [Swift Transformers](https://github.com/huggingface/swift-transformers) by Hugging Face (Apache 2.0)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference (Apache 2.0)
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus (MIT)
- Models: OpenAI Whisper (MIT), Distil-Whisper (MIT), NVIDIA Parakeet (CC-BY-4.0), Qwen3 and Qwen3-TTS (Apache 2.0), Gemma 4 (Gemma license), Llama 3.2 (Llama 3.2 Community License)
