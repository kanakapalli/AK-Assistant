# AK Assistant — Smart Search & Memory: Implementation Plan

**Feature set:** on-device text embeddings (EmbeddingGemma 2) powering search, “ask your meetings”, multilingual commands and personal memory.
**Status:** Phase 0 and Phase 1 implemented (not yet built) · **Written:** 9 Oct 2026 · **Owner:** Anurag
**Applies to:** AK Assistant 0.1.0 (Swift 5 mode, macOS 15+, mlx-swift-lm 3.31.4 / mlx-swift 0.31.6, FluidAudio 0.17.4)

---

## 0. Progress log

**9 Oct 2026: Phase 0 + Phase 1 written** (not yet compiled; first build expected to need small fixes)
- Model path: **option C** (EmbeddingGemma 300M, `mlx-community/embeddinggemma-300m-8bit`, via `MLXEmbedders`, already in mlx-swift-lm 3.31.4). The `MLXEmbedders` product was added to the target. EmbeddingGemma 2 can replace it behind `TextEmbedder` after the MLX upgrade.
- New folder `AKAssistant/Memory/`: `TextEmbedder` (roles/prefixes, vector maths, stable hash), `GemmaEmbedder`, `EmbeddingService`, `IndexEntry`/`IndexedSource` (own `Index.store`), `VectorIndex` (vDSP), `MemoryIndexer` (fingerprints, background sync on save, pauses while busy), `MemoryCenter` (hybrid search), `CommandIntents` + `CommandIntentCatalog` (51 intents, English/Hindi/Telugu examples, slot filling).
- AI key: parser → meaning match (≥ 0.80 run, risky always confirm; 0.65–0.80 answer + “Did you mean” buttons) → AI.
- Settings › Search & memory: on/off (downloads model), index status, what to index, command matching (Off / Suggest only / Run safe commands), rebuild, delete.
- Not yet: Models-page card, search UI in Meetings/History (Phase 2), eval sets.

## 1. Goal

Give AK Assistant a private, on-device “memory” of everything it has heard and written, so it can:

- find things by **meaning**, not exact words (meetings, history, notes, files);
- **answer questions** about past meetings and notes with sources;
- understand **Mac commands in any phrasing or language** in milliseconds, without loading the 2.3 GB chat model;
- **organise** meetings and to-dos automatically (related meetings, merged to-dos, tags, chapters).

Everything stays on the Mac. The only network use is the one-time model download.

## 2. Features in scope

| ID | Feature | Area | Phase | Effort |
|---|---|---|---|---|
| F14 | Instant multilingual commands | Mac commands | 1 | S |
| F16 | “Did you mean…” command suggestions | Mac commands | 1 | S |
| F1 | Search meetings by meaning | Meetings | 2 | M |
| F2 | Ask your meetings (answers with sources) | Meetings / AI | 2 | M |
| F8 | Search history by meaning | History | 2 | S |
| F3 | Related meetings | Meetings | 3 | S |
| F4 | Open to-dos across meetings, de-duplicated | Meetings | 3 | M |
| F6 | Auto-tag meetings | Meetings | 3 | S |
| F12 | Personal notes memory (“remember that…”) | AI | 3 | M |
| F5 | Topic chapters in long meetings | Meetings | 4 | M |
| F9 | Snippets by voice | Dictation | 4 | M |
| F10 | Personal vocabulary hints | Dictation | 4 | M |
| F11 | Assistant uses your memory in answers | AI | 4 | M |
| F15 | Smarter file opening | Mac commands | 4 | S |
| F13 | Ask your files (chosen folders) | AI | 5 | L |
| F7 | Follow-up briefing before a meeting | Meetings | 5 | L |

S ≈ 1–2 days, M ≈ 3–5 days, L ≈ 1–2 weeks (one developer).

## 3. Key decisions

### 3.1 Which embedding model, and how to run it

| Option | What | Pros | Cons |
|---|---|---|---|
| **A. EmbeddingGemma 2 via `EmbeddingGemma2Swift`** | Third-party MLX Swift package (MIT; model Apache 2.0). 8-bit weights ≈ 481 MB (text + vision). Warm M3: ~0.1 s for 7 short inputs, ~0.29 s for a 959-token input. | Newest model; Apache 2.0; prefixes and Matryoshka handled; tested on Mac. | Needs **mlx-swift 0.32.3** (project has 0.31.6) and Swift 6.3 tools → must upgrade mlx-swift-lm first; new third-party dependency; 4-bit profile marked experimental. |
| **B. Port EmbeddingGemma 2 text encoder ourselves** | Add `embedding_gemma2_text` (hidden 512, 24 layers, 262k vocab) next to mlx-swift-lm's `MLXEmbedders` models. | No new package; text-only (smallest); full control. | ~1 week of model-porting work and numeric validation against the Python reference. |
| **C. EmbeddingGemma (v1, 300M) via `MLXEmbedders`** | Already supported by the package the app uses (`gemma3` model type). | Works **today**, zero new dependencies; text quality almost identical (MTEB multilingual **61.15** vs EG2 **61.36**). | v1 licence is the Gemma Terms (the Hugging Face repo is gated); EG2's gains are mostly code and multimodal, which we don't need. |

**Decision:** put the model behind one `TextEmbedder` protocol (§4.1), so features never depend on which model runs.

- **Phase 0, day 1 (spike):** try **A**. Upgrade mlx-swift-lm to a release built on mlx-swift ≥ 0.32.3, add `EmbeddingGemma2Swift`, and confirm the chat models still load and generate.
- **If A blocks** (package conflict or Xcode/Swift version): ship with **C** and move to EG2 later through **A** or **B**.
- The index records the model ID, so a later model switch simply re-embeds in the background (§4.4).

### 3.2 Vector size and storage

- **256 dimensions** (Matryoshka truncation, re-normalised): 60.41 vs 61.36 at 768d on MTEB multilingual, at a third of the memory. Stored as Float32 (1 KB per entry).
- **Brute-force search, no vector database.** 50,000 entries × 256 = 12.8 M floats ≈ 51 MB in RAM. One `vDSP`/BLAS matrix-vector product ranks everything in about 1–3 ms.
- **Separate SwiftData store** `~/Library/Application Support/AK Assistant/Index.store`. It's rebuildable and disposable, never mixed with meetings or history, so deleting it can't lose user data.

### 3.3 Search quality

- **Hybrid ranking:** `score = 0.8 × cosine + 0.2 × keyword score`. Keywords keep names, numbers and IDs (“INV-2041”, “Priya”) precise, where pure embeddings are fuzzy.
- **Correct prefixes:**
  - queries: `task: search result | query: {text}`
  - documents: `title: {meeting title or none} | text: {text}`
  - command and tag matching: `task: classification | query: {text}`

### 3.4 Safety rules

- **Risky Mac commands** (quit, lock, sleep, empty Trash, Wi-Fi off, restart, shut down, log out, close window/tab) **never auto-run from an embedding match**: they always show Run / Cancel.
- **Answers about meetings or notes** must cite sources. When retrieval finds nothing relevant (top score below the threshold), the assistant says it couldn't find it rather than guessing.

## 4. Phase 0 — Foundation (4–5 days)

Everything after this phase is built on these pieces.

### 4.1 New files (`AKAssistant/Memory/`)

```
Memory/
├── TextEmbedder.swift        protocol + EmbeddingRole + prefix formatting
├── EmbeddingGemmaEmbedder.swift   option A or C behind the protocol
├── EmbeddingService.swift    @MainActor: load/unload, batching, idle unload, warm-up
├── IndexEntry.swift          SwiftData @Model for the index
├── VectorIndex.swift         in-memory matrix + vDSP search + filters
├── Chunker.swift             text → chunks with titles
├── Indexer.swift             background job queue, backfill, re-index
├── HybridSearch.swift        vector + keyword ranking, date filters
└── MemoryStore.swift         container for Index.store, notes, snippets
```

### 4.2 Core API sketch

```swift
enum EmbeddingRole {
    case query                          // what the user is searching for
    case document(title: String?)       // things being searched
    case classify                       // commands, tags (symmetric)

    func format(_ text: String) -> String {
        switch self {
        case .query: return "task: search result | query: \(text)"
        case .document(let title): return "title: \(title ?? "none") | text: \(text)"
        case .classify: return "task: classification | query: \(text)"
        }
    }
}

protocol TextEmbedder: AnyObject {
    var modelID: String { get }          // e.g. "embeddinggemma-2@256"
    var dimensions: Int { get }          // 256
    func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]]  // L2-normalised
}

@MainActor @Observable
final class EmbeddingService {
    private(set) var state: State        // notDownloaded, downloading(p), loading, ready, failed
    func prepare() async throws          // load once; reuse in-flight load (same pattern as LLMService)
    func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]]  // batches of 16
    func unload()                        // after 10 idle minutes
}
```

### 4.3 Index data model

```swift
@Model final class IndexEntry {
    var id: UUID
    var kind: String          // meetingParagraph, meetingSummary, keyPoint, decision, actionItem,
                              // dictation, answer, note, snippet, fileChunk, commandIntent
    var sourceID: UUID        // Meeting.id, DictationRecord.id, Note.id…
    var locator: String?      // segment id / item id / "file path#chunk"
    var text: String          // exact text embedded (also used for keyword scoring and display)
    var title: String?        // meeting title, file name…
    var sourceDate: Date      // for “last week” filters
    var vector: Data          // [Float] × dimensions
    var modelID: String       // which model made it (re-embed when it changes)
}
```

`VectorIndex` loads all entries for the current `modelID` into one contiguous `[Float]` matrix at launch (in the background) and keeps it in sync as entries are added or removed. Searches take a filter (kinds, date range, source IDs).

### 4.4 Indexer

- **Triggers:**
  - a meeting reaches `done` (after the clean-up pass and notes);
  - a dictation or AI answer is saved;
  - a note, snippet or to-do changes;
  - a speaker is renamed;
  - the model changes;
  - first enable (backfill).
- **Chunking:**
  - each meeting transcript paragraph (already ≤ 60 s) becomes one entry, with `title = meeting title` and the speaker name prefixed;
  - summary, each key point, decision and to-do become one entry each;
  - dictations under 4 words are skipped;
  - anything over ~1,500 tokens is split into ~300-word chunks with a 50-word overlap.
- **Scheduling:**
  - runs at utility priority;
  - **pauses while recording, dictating or the AI is answering**, so it doesn't compete with the GPU or Neural Engine;
  - batches of 16;
  - resumable after quit (unprocessed sources are found by comparing source IDs).
- **Deletion:** deleting a meeting or history item removes its entries.

### 4.5 Model management and settings

- **Models page:** a “Search & memory” card (download, size, delete, runtime info), using `ModelManager` patterns.
- **New Settings › Search & memory section** (`UI/MemorySettings.swift`):
  - Turn on smart search & memory (default off until downloaded; onboarding offers it later);
  - Index: meetings ✓, history ✓, notes ✓, files (Phase 5);
  - Use my memory in AI answers (Phase 4, default on);
  - Command matching: Off / Suggest only / Run safe commands (default: Run safe commands);
  - Index size and entry count, **Rebuild index**, **Delete index**.

### 4.6 Done when

- [ ] Embeds 100 short texts in < 1.5 s warm on an M-series Mac; first load < 3 s.
- [ ] Backfill of existing meetings and history completes with progress shown, and survives quit/relaunch.
- [ ] Search over 50k synthetic entries returns top-10 in < 10 ms.
- [ ] Memory: model + index stay under ~700 MB extra with everything else loaded (to be measured).
- [ ] Unit tests: prefix formatting, chunker, vector math (cosine = 1 for identical, normalisation after truncation), index add/remove/filter.

## 5. Phase 1 — Commands (3 days): F14, F16

**Flow (new step in the middle):**

```
transcript → CommandParser (regex, exact)  ──match──▶ run
                 │ no match
                 ▼
          IntentRouter (embeddings)  ──≥ 0.80──▶ fill slots → run (safe) / confirm (risky)
                 │ 0.65–0.80 ─────────────────▶ “Did you mean…” card with 3 Try buttons (F16)
                 │ < 0.65
                 ▼
          chat model (ACTION: … fallback, as today) or a normal answer
```

- **Intent catalogue:** `Resources/command-intents.json` holds one entry per command template, each with 5–15 example phrases in English, Hindi (Devanagari and romanised), Telugu and others. `ToolCatalog` phrases seed it. All examples are embedded once and stored as `kind = commandIntent`; the catalogue is re-embedded only when its version changes.
- **Slot filling** after the intent is chosen:
  - app names: `AppFinder` on the leftover words;
  - numbers and durations: the existing regex helpers plus a small number-word table (English and Hindi: “das” = 10, “bees” = 20);
  - search terms: the text after the matched verb.
  - If a required slot is missing, fall through to the chat model.
- **Thresholds** are tuned on the eval set (§10); they're starting values.
- **“Did you mean…” card:** a new `CommandBadge` style on the answer card listing the 3 closest commands as Try buttons (the same machinery as Learn's Try buttons).
- **Learn:** add a “Say it your way” note to the Commands tab.

**Done when:** ≥ 95% intent accuracy on the 200-phrase multilingual eval set; 0 risky commands auto-run; median added latency < 30 ms.

## 6. Phase 2 — Search and ask (6–8 days): F1, F2, F8

### F1 Search meetings by meaning
- The Meetings search field switches to hybrid search when the index is ready, and to plain text search otherwise.
- Results are grouped by meeting, with the matching paragraph highlighted.
- Clicking a result selects the meeting, opens the Transcript tab, scrolls to the paragraph and offers ▶ Play from here.
- Date chips: Any time / This week / This month.

### F8 Search history by meaning
- The same hybrid search in History, with Dictation / AI / All filters kept.

### F2 Ask your meetings
1. **Routing.** An `IntentRouter` class “question about my meetings/notes” is matched by embeddings against example questions (“what did we decide…”, “who said…”, “in the last meeting…”). Explicit phrases (“in my meetings”, “last meeting”) always route.
2. **Time filters.** `NSDataDetector`-based parsing of “yesterday”, “last week”, “on Tuesday”, “in September” becomes a date range.
3. **Retrieval.** Top 8 hybrid results (paragraphs, summaries, decisions, to-dos), at most 2 per meeting at first, then filled; context limited to ~2,500 tokens.
4. **Answer.** `LLMService.generate` with “answer only from the context; cite like [1]; say you couldn't find it if the context doesn't contain it”, then streamed into the answer card and spoken as usual.
5. **Sources.** Sources appear under the answer as chips (meeting title · time). Clicking one opens Meetings at that line. The answer card gets a new `sources` field.
6. **Not found.** If the top score is < 0.5: “I couldn't find that in your meetings.” No fabricated answer.

**Done when:** recall@5 ≥ 0.8 on the 50-question personal eval set; every answer has at least one valid source link; latency to first words < 2 s warm.

## 7. Phase 3 — Organise (5–6 days): F3, F4, F6, F12

- **F3 Related meetings.** Meeting vector = normalised mean of its paragraph vectors, blended 50/50 with the summary vector. The Summary tab shows up to 3 meetings with similarity > 0.6. Computed on demand, cached in memory.
- **F4 Open to-dos.** A new sidebar page **To-dos**:
  - every unticked action item from all meetings, grouped by owner;
  - items with similarity > 0.85 merge into one row listing all meetings it came from;
  - ticking a merged row ticks every copy;
  - filters: owner, due, meeting tag.
- **F6 Auto-tags.**
  - Tags are user-defined in Settings (name + one-line description), seeded with standup, client call, hiring, planning, 1:1.
  - A meeting gets a tag when its vector matches the tag description above a threshold.
  - Tags are editable per meeting and filter the meetings list.
  - New `tagsData` on `Meeting`.
- **F12 Personal notes memory.**
  - New `@Model Note { id, text, createdAt, source }` in `Meetings.store` (renamed conceptually to the user data store) or its own store.
  - “Remember that … / note that …” saves a note (confirmation in the popup).
  - Questions route to notes first, then meetings.
  - A Notes list lives under History (filter chip), with delete.
  - “Forget that …” finds and deletes the best match after confirmation.

## 8. Phase 4 — Deeper features (8–10 days): F5, F9, F10, F11, F15

- **F5 Topic chapters.**
  - Embedding-based TextTiling: compare windows of 3 paragraphs on each side; a boundary falls where similarity hits a local minimum below the running mean − 1 SD; minimum chapter length 2 minutes.
  - The chat model names each chapter in ≤ 4 words.
  - Shown as an outline beside the Transcript and in the Markdown export. New `chaptersData` on `Meeting`.
- **F9 Snippets by voice.**
  - New `Snippet { name, text }` with a Snippets page in Settings.
  - AI key: “insert / paste my …” is routed and matched by the snippet name and text, then inserted with `TextInserter`.
  - Ambiguous matches show the top 3.
- **F10 Personal vocabulary hints.**
  - Collect proper nouns and unknown words from transcripts (`NSSpellChecker`), then cluster variants with embeddings + edit distance (“Priya / Pria / Preeya”).
  - Suggest them in Settings › Vocabulary.
  - Whisper: pass them as prompt tokens. Parakeet and Nemotron have no prompt, so apply them as a **post-correction map** (replace near-miss spellings).
- **F11 Assistant uses your memory.**
  - For normal questions, retrieve the top 3 from notes and recent history; if the best score is > 0.6, add them as background context.
  - A small “Used your notes” chip on the answer card shows which.
  - Setting toggle.
- **F15 Smarter file opening.**
  - “Open the spreadsheet with the Q3 numbers” → `mdfind` keyword candidates (≤ 50) → rerank by embedding of file name + folder + the first 1 KB of text for text, Markdown, PDF and Office files.
  - Open the best match, or show the top 3.

## 9. Phase 5 — Files and briefings (2–3 weeks): F13, F7

- **F13 Ask your files.**
  - Settings › Search & memory › Folders, with Add Folder… (non-sandboxed, but kept to folders the user picks).
  - Extraction: txt/md (direct), rtf/docx (`NSAttributedString`), PDF (`PDFKit`), pages/keynote skipped at first.
  - Index ~300-word chunks with the file name as title; FSEvents watcher re-indexes changed files.
  - Caps: 2,000 files and 20 MB per file per folder, with progress and a size readout.
  - “In my files…” questions route here; answers cite file + page, and a click opens the file.
- **F7 Follow-up briefing.**
  - Manual first: in Meetings, **Prepare brief** asks for a topic (or uses a selected meeting) and finds related meetings.
  - The chat model writes “Last time / Decided / Still open / Suggested questions”.
  - Later: two minutes into a live meeting, suggest “This looks like a follow-up to *X*”; optional Calendar (EventKit) integration to prepare briefs before scheduled meetings.

## 10. Testing and evaluation

| Set | Contents | Metric | Target |
|---|---|---|---|
| Commands | 200 phrases: English, Hindi (both scripts), Telugu, odd phrasings, plus 50 non-commands | intent accuracy; false-run rate | ≥ 95%; 0 risky, < 1% safe false runs |
| Meeting search | 50 queries over your real meetings with expected paragraphs | recall@5, MRR | ≥ 0.8, ≥ 0.6 |
| Ask your meetings | 30 questions with known answers + 10 unanswerable | correct + cited; correct refusal | ≥ 80%; ≥ 9/10 |
| Related meetings, to-do merge | 20 hand-labelled pairs each | precision | ≥ 0.85 |
| Performance | embed 100 short texts; search 50k; first load | time | < 1.5 s; < 10 ms; < 3 s |

- Unit tests for the chunker, prefixes, vector maths, date parsing, slot filling and the summary/answer parsers.
- A hidden debug screen (⌥-click the Search & memory header) shows the top 20 scores for a query, to tune thresholds.
- Log under `com.natfirst.akassistant`, category `Memory`, with timings for every embed and search.

## 11. Performance and memory budget

| Loaded at once | Approx. |
|---|---|
| Parakeet Ultra (speech) | ~650 MB |
| Qwen3 4B (chat, 4-bit) | ~2.3 GB |
| Qwen3-TTS 0.6B (voice) | ~1 GB |
| EmbeddingGemma (text, 8-bit) | ~250–480 MB (measure in Phase 0) |
| Vector index (50k × 256 floats) | ~51 MB |

- **16 GB Macs:** comfortable.
- **8 GB Macs:**
  - load the embedder on demand and unload it after 10 idle minutes;
  - index only while nothing else is running;
  - command matching uses a small pre-computed intent matrix (~1 MB) but still needs the model to embed the spoken phrase, so it falls back to regex + chat if the embedder isn't loaded.

## 12. Risks and mitigations

| Risk | Mitigation |
|---|---|
| MLX upgrade for option A breaks chat or MLX speech models | Spike on a branch; run all model smoke tests; fall back to option C |
| Third-party `EmbeddingGemma2Swift` is young | Wrap behind `TextEmbedder`; pin version; keep option B/C ready |
| Embedding false matches trigger wrong commands | Thresholds from eval set; risky commands always confirm; “Command matching” setting |
| Hallucinated answers about meetings | Context-only prompt, mandatory citations, refusal below score threshold |
| GPU contention slows dictation | Indexer pauses during recording/answers; utility priority |
| Index drifts from data | Source-ID reconciliation on launch; Rebuild index button; model ID per entry |
| Hindi/Telugu quality weaker than English | Native-script and romanised examples in intents; evaluate per language |

## 13. Data model changes (summary)

| Store | Change | Migration |
|---|---|---|
| `Index.store` (new) | `IndexEntry` | New file; disposable |
| `Meetings.store` | `Meeting.tagsData`, `Meeting.chaptersData` (Data, default empty) | Lightweight (new optional/defaulted attributes) |
| User data (new or `Meetings.store`) | `Note`, `Snippet`, `Tag` models | New entities |
| `UserDefaults` | `memoryEnabled`, `memoryIndexMeetings/History/Notes/Files`, `memoryInAnswers`, `commandMatching`, `memoryFolders`, `embeddingModelID` | Registered defaults |

## 14. Timeline (one developer)

| Week | Work |
|---|---|
| 1 | Phase 0: model spike (A vs C), EmbeddingService, index, indexer, settings, backfill |
| 2 | Phase 1: intent router, slot filling, “Did you mean…”, command eval set |
| 3–4 | Phase 2: meeting/history search UI, Ask your meetings with sources, search eval sets |
| 5 | Phase 3: related meetings, To-dos page, tags, notes memory |
| 6–7 | Phase 4: chapters, snippets, vocabulary, assistant memory, smarter file open |
| 8–9 | Phase 5: Ask your files, briefings |

Ship after each phase; every phase is useful on its own.

## 15. Open questions

1. Option A needs Swift 6.3 tools. Which Xcode version is installed? If it's below that, start with option C.
2. Should notes and snippets live in `Meetings.store` (renamed to a general user store) or a new `UserData.store`?
3. Default for command matching: “Run safe commands” or “Suggest only” for the first release?
4. Which languages besides English and Hindi matter most for the command examples (Telugu, Tamil, …)?
5. Folder indexing (F13): any folders that must never be indexed?

## 16. References

- EmbeddingGemma 2 model card: https://huggingface.co/google/embeddinggemma-2
- MLX conversions: https://huggingface.co/mlx-community/embeddinggemma-2-4bit (also 5-bit, 6-bit)
- EmbeddingGemma 2 on MLX Swift: https://github.com/Obscyra-app/EmbeddingGemma2Swift
- `MLXEmbedders` (EmbeddingGemma v1 support) in mlx-swift-lm: https://github.com/ml-explore/mlx-swift-lm/tree/main/Libraries/MLXEmbedders
- Current architecture: `docs/index.html` (AK Assistant Handbook)
