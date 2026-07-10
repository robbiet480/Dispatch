# Dispatch Plan 32: Voice answers with on-device transcription

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** answer questions by voice (GitHub issue #17) — tier 1 of the three-tier voice design: an inline mic button on every text-shaped survey input (tokens, people, note, location, and text-field numbers) that streams live on-device transcription into the existing answer flow, with question-type-aware parsing ("Alice, Bob and Carol" → three tokens; "about seven" → `7`), plus the watch's minimal dictation-confirmation upgrade (dictated token answers split and confirmed as chips before filing). Mic + speech permissions join the onboarding cascade; everything is on-device, and the privacy policy says so explicitly.

**Tier map (design discussion, Robbie 2026-07-10).** Tier 1 (this plan): inline mic on iPhone survey inputs + watch dictation confirmation. Tier 2 (NOT this plan — explicit follow-up, Task 7 files the issue): hands-free filing via Siri/App Intents parameter-resolution dialogs + Action button mapping. Tier 3 (future): a watch voice-first filing flow.

**Architecture:** transcription is app-side behind a small protocol (`SpeechTranscribing`) with THREE implementations — the primary `SpeechAnalyzer`/`SpeechTranscriber` engine (iOS 26 Speech framework, on-device model assets via `AssetInventory`), an `SFSpeechRecognizer` fallback locked to `requiresOnDeviceRecognition = true` for locales the new stack doesn't support, and a scripted mock for UI tests. Parsing is kit-side and pure (`SpokenAnswerParser` in DispatchKit) so token-splitting and number-word rules are unit-testable without any audio. The mic button feeds the SAME `onAnswer` path every keyboard input uses — voice is an input method, not a new answer pipeline. The watch has NO Speech framework at all (verified below), so it keeps system dictation via `TextField` and gains only the kit parser + a confirmation UI.

**Tech Stack:** Speech.framework (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`, `SFSpeechRecognizer` fallback), AVFAudio (`AVAudioEngine` mic tap, `AVAudioSession`), SwiftUI, DispatchKit pure parsing, XCTest/Swift Testing.

## Verified platform facts (pre-verified 2026-07-10 — the spike re-confirms at runtime)

Checked against https://developer.apple.com/documentation/speech (per-symbol availability metadata) AND empirically against the local Xcode 26 SDKs (`Speech.framework` swiftinterface, iPhoneOS + WatchOS platforms):

- **`SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber`, `AssetInventory`: iOS 26.0+ / iPadOS 26.0+ / macOS 26.0+ / tvOS 26.0+ / visionOS 26.0+ — and `watchOS, unavailable`.** The doc metadata lists no watchOS row for any of them (https://developer.apple.com/documentation/speech/speechanalyzer, `.../speechtranscriber`, `.../dictationtranscriber`, `.../assetinventory`), and the SDK interface stamps `@available(watchOS, unavailable)` on the whole module surface.
- **The watchOS 26 SDK contains NO `Speech.framework` at all** (`Platforms/WatchOS.platform/.../SDKs/WatchOS.sdk/System/Library/Frameworks/` — absent). `SFSpeechRecognizer` is likewise iOS 10+/macOS 10.15+/visionOS with **no watchOS availability** (https://developer.apple.com/documentation/speech/sfspeechrecognizer). **Consequence: there is no programmatic speech-to-text on the watch. Tier 3 can only ever be system dictation UI; this plan's watch task is parser + confirmation, no Speech API.**
- **Our deployment targets are already iOS 26.0 / watchOS 26.0** (`project.yml`), so the SpeechAnalyzer path needs **no `#available` gates on iOS**. The fallback fork is about **locale/asset support at runtime**, not OS version.
- **API shape (from the iOS 26 swiftinterface):** `final public actor SpeechAnalyzer` with `analyzeSequence<InputSequence>(_:) async throws -> CMTime?` over `AsyncSequence<AnalyzerInput>` and `start(inputSequence:)`/`finalizeAndFinishThroughEndOfInput()`; `final public class SpeechTranscriber: SpeechModule, LocaleDependentSpeechModule` with `init(locale:preset:)`, presets `.transcription`/`.progressiveTranscription`/`.timeIndexedProgressiveTranscription` (+ alternatives variants), `ReportingOption.volatileResults`/`.fastResults`, `Result { text: AttributedString; isFinal: Bool }` on an `AsyncSequence` `results` property, `static var isAvailable: Bool`, `static var supportedLocales: [Locale]`, `static func supportedLocale(equivalentTo:) async -> Locale?`; `AssetInventory.status(forModules:) async -> Status` (`unsupported`/`supported`/`downloading`/`installed`), `assetInstallationRequest(supporting:) async throws -> AssetInstallationRequest?` with `downloadAndInstall() async throws` + `ProgressReporting`, `reserve(locale:)`/`release(reservedLocale:)`, `maximumReservedLocales`.
- **Open runtime questions the spike MUST answer** (docs don't settle them): whether the SpeechAnalyzer path requires `SFSpeechRecognizer.requestAuthorization` (WWDC25 material implies the new stack needs only mic access for live audio, but this is unverified — the fallback path definitely requires it); simulator behavior (asset download + transcription on sim vs device); first-use model-download size/latency and whether `.downloading` is observable; volatile-result cadence.

## Design decisions (decide + log)

- **The fork is locale support, not OS version.** Engine resolution at mic-button appearance: `SpeechTranscriber.isAvailable` AND `await SpeechTranscriber.supportedLocale(equivalentTo: .current) != nil` → SpeechAnalyzer engine; else `SFSpeechRecognizer(locale:)` where non-nil AND `supportsOnDeviceRecognition` → fallback engine with `requiresOnDeviceRecognition = true` pinned (privacy invariant: **never** network recognition); else the mic button is HIDDEN (typed input unaffected). Resolution is cached per app run and re-checked when locale changes.
- **Voice writes through the existing answer path.** The mic button never grows a parallel store: token/people questions commit parsed tokens via `onAnswer(.tokens(...))` exactly like `TokenEntryView.commitDraft`; note/location append transcribed text to the field's local draft (the `LocalTextEditorField` debounce/flush machinery then owns it, unchanged); number (`.textField` style only) commits the parsed numeric string via `onAnswer(.number(...))`. Non-text number styles (slider/stepper/dial/tapCounter/scale) get NO mic in v1 — they have no text surface. Plan 28's `time` type (PR #27, in flight) is out of scope; rebase-aware note: if it lands first, `.time` simply gets no mic button (nothing to do).
- **Volatile vs. final results drive the UI.** Live (volatile) text renders dimmed in a transcript strip above the input; finalized segments are parsed and committed segment-by-segment. Preset: `.progressiveTranscription` (spike confirms it reports `volatileResults`; otherwise construct options explicitly with `reportingOptions: [.volatileResults, .fastResults]`).
- **Parsing is kit-pure and question-type-aware** (`SpokenAnswerParser`, no Speech/AVFoundation imports — testable on any platform, shared with the watch): **tokens** — split on commas, "and", "&" ("Alice, Bob and Carol" → ["Alice", "Bob", "Carol"]), trim, drop empties, preserve order, no dedupe beyond the existing last-token guard; **number** — strip filler ("about", "around", "roughly", "maybe", "like", "approximately"), digits pass through ("7", "7.5"), English number words zero…twenty + tens + compounds ("twenty five" → 25) + "point" decimals ("seven point five" → 7.5); unparseable → nil (UI keeps the raw transcript visible for manual fix, commits nothing); **note/location** — pass-through (no parsing). **English-only word parsing in v1**, documented in code; digits work in any locale.
- **Audio session coordination with the ambient-sound sensor:** `AudioProvider.capture()` sets `.record/.measurement` and deactivates in a `defer` within the capture window (~seconds at survey start). The voice engine claims the session (`.record`, mode `.spokenAudio`) only while the mic button is actively recording and deactivates with `.notifyOthersOnDeactivation` on stop. A capture-window collision is possible on the first survey page; the implementation must verify empirically and, if the two fight, delay mic-button enablement until the capture core's audio provider resolves (it is bounded by the 10s capture timeout). Record the observed behavior in a code comment.
- **Permissions: speech recognition joins the cascade as its own sequenced step** (after microphone, before photos): `SFSpeechRecognizer.requestAuthorization` wrapped in the cascade's continuation+`OneShotResumeGuard` pattern, plus `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` in `project.yml`. Requested unconditionally (the fallback engine definitely needs it; if the spike proves SpeechAnalyzer needs it too, first-tap would otherwise ambush the user mid-survey — exactly what the cascade exists to prevent). Existing installs get a **one-time upgrade top-up** (the motion/medications pattern, new key `permissions.speechRequested`, flag written BEFORE the step for crash tolerance). The microphone purpose string in `project.yml` must be REWRITTEN — it currently promises the mic is used for decibel sampling only, which becomes false.
- **Privacy policy edits (`docs/privacy-policy.md`) ship in the same task as the permission:** the "Ambient sound level" bullet's "no audio is ever recorded or stored" claim is scoped to the sensor, and a new "Voice answers" bullet states: transcription happens **entirely on-device** (Apple's on-device speech models; the fallback recognizer is pinned to on-device-only), audio is processed in memory and **never recorded, stored, or transmitted**, the transcript becomes an ordinary answer (stored/synced like typed text), and the mic activates only while the button is held/active. This keeps the "No analytics… no third-party SDKs… network connections only to Apple services" section true: the only new network activity is Apple's one-time model-asset download via `AssetInventory` — disclose it in the Apple services section.
- **Test gating absolute:** under `--ui-testing`/`--mock-sensors` the engine resolver returns the scripted mock (no AVAudioEngine, no Speech calls, no dialogs — the PermissionCascade gate already covers the cascade step). The mock emits a scripted volatile→final sequence so UI tests can drive the full mic flow deterministically.
- **Watch scope is parser + confirmation ONLY** (no Speech API exists there): dictated text for token/people questions is split by `SpokenAnswerParser` and previewed as removable chips with a "File N" button — today `WatchQuestionView.textValue` files the whole utterance as ONE token, which is wrong the moment dictation says "coffee, toast and eggs". Note/location keep direct filing (pass-through, nothing to confirm beyond today's behavior).
- **DispatchKit gains no platform dependencies:** `SpokenAnswerParser` is pure Swift/Foundation. All Speech/AVFAudio code lives in `App/Sources/Voice/` (app target only).

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → `swift test` green, per task. App target verified with `xcodebuild build-for-testing` (UI suite reserved for the merge gate); watch scheme builds for the watch task.
- No schema changes, no v2 format changes, no new entitlements. New Info.plist material is limited to `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` + the rewritten mic purpose string (both `project.yml`).
- The fallback recognizer NEVER runs with `requiresOnDeviceRecognition == false` — pin it with an assertion and a test on the engine's configuration type. No audio buffer is ever written to disk.
- Every platform-behavior claim resolved by the spike lands as a code comment citing https://developer.apple.com/documentation/speech (four-strikes rule); the spike findings section below is filled in before any dependent task starts.
- Accessibility per the plan-17 bar: the mic button carries `accessibilityIdentifier("voice-input")`, a state-aware label ("Start/Stop voice input"), `.isSelected` while recording; the live transcript strip is announced via `accessibilityLabel`; Dynamic Type XXL survives; VoiceOver users can reach STOP.
- Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing (standing instruction). Do NOT bump the build number.

---

### Task 1 (CRITICAL, blocks everything): SpeechAnalyzer empirical spike

The architecture forks on facts the docs don't fully settle. This task produces **recorded findings, not shipping code** — a throwaway probe, then this plan doc is amended.

**Files:**
- Create (temporary): `App/Sources/Voice/SpeechSpikeView.swift` — a debug-only harness screen (gated behind `#if DEBUG`, reachable via a hidden Settings developer row), DELETED in Task 3 once the real engine replaces it
- Modify: this plan doc ("Spike findings" subsection below)

- [ ] **Step 1: Compile-time probe.** Add the harness referencing `SpeechAnalyzer`, `SpeechTranscriber(locale:preset:)`, `AssetInventory.status(forModules:)`, `assetInstallationRequest(supporting:)`, `SpeechTranscriber.Result.text/.isFinal`, `AnalyzerInput(buffer:)` — confirm it compiles against the pinned Xcode's iOS SDK with zero availability gates (deployment target 26.0). Also confirm the watch target does NOT link Speech (attempt `import Speech` in a scratch watch file → expect FAILURE; delete the scratch file; record).
- [ ] **Step 2: Runtime probe — file-based first (deterministic, no mic):** bundle a short spoken test clip and run `analyzer.analyzeSequence(from: AVAudioFile)`; record on BOTH simulator and device: (a) does transcription succeed without EVER calling `SFSpeechRecognizer.requestAuthorization`? (THE authorization question); (b) `AssetInventory.status` before/after — download size, observability of `.downloading`, `AssetInstallationRequest.progress`; (c) `SpeechTranscriber.supportedLocales` contents; (d) result cadence with `.progressiveTranscription` — are `isFinal == false` volatile results delivered, and at what latency?
- [ ] **Step 3: Runtime probe — live mic:** AVAudioEngine input tap → `AsyncStream<AnalyzerInput>` → `analyzer.start(inputSequence:)`; on device: end-to-end latency feel, behavior when the capture core's `AudioProvider` holds the audio session (start a real survey, tap the probe within the capture window), behavior on route change (AirPods), and `finalizeAndFinishThroughEndOfInput()` semantics on stop.
- [ ] **Step 4: Fallback probe:** for an unsupported-locale simulation, confirm `SFSpeechRecognizer(locale:).supportsOnDeviceRecognition` + `requiresOnDeviceRecognition = true` produces results with the network disabled (airplane-mode device test) — this is the privacy claim's proof.
- [ ] **Step 5: Record.** Fill in "Spike findings" below (authorization answer, session-collision answer, preset choice, download UX, sim-vs-device deltas, fallback proof) and adjust Tasks 3–5 where reality diverges — IN THE SAME COMMIT as the findings so the plan never lies. Commit — `git commit -m "spike: SpeechAnalyzer runtime probe + plan 32 findings (refs #17)"` → push.

#### Spike findings (filled by Task 1)

- Authorization required for SpeechAnalyzer path: _TBD_
- Audio session vs AudioProvider capture window: _TBD_
- Preset/options that deliver volatile results: _TBD_
- Asset download size / UX / simulator behavior: _TBD_
- Fallback on-device proof (airplane mode): _TBD_

### Task 2: Kit — SpokenAnswerParser (token splitting + spoken-number parsing)

**Files:**
- Create: `Sources/DispatchKit/Capture/SpokenAnswerParser.swift`
- Test: create `Tests/DispatchKitTests/SpokenAnswerParserTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**
- `SpokenAnswerParser.tokens(from: String) -> [String]`
- `SpokenAnswerParser.number(from: String) -> String?` (numericResponse-compatible string, nil when unparseable)

- [ ] **Step 1: Write the failing tests.** Tokens: `"Alice, Bob and Carol"` → `["Alice", "Bob", "Carol"]`; `"coffee and toast"` → two; `"Sam"` → one; `"Anne Marie and Bob"` → `["Anne Marie", "Bob"]` (multi-word tokens survive — "and"/comma are separators, embedded spaces are not); `"salt & pepper"` → two; `"apples, and oranges"` (Oxford comma) → two, no empties; `"Sandy"` → `["Sandy"]` (no false split on token-internal "and": only whole-word `and` separates); empty/whitespace → `[]`. Numbers: `"7"` → `"7"`; `"about seven"` → `"7"`; `"twenty five"`/`"twenty-five"` → `"25"`; `"a hundred"` → `"100"`; `"seven point five"`/`"7.5"` → `"7.5"`; `"roughly fifteen"` → `"15"`; `"zero"` → `"0"`; `"maybe like twelve"` → `"12"`; punctuation tolerance (`"Seven."` → `"7"`); `"a lot"` → nil; `""` → nil. Output strings must satisfy the numericResponse contract (parse with `Double(_:)`).
- [ ] **Step 2: Run `swift test` — expect FAIL.**
- [ ] **Step 3: Implement** — pure Foundation, doc comment stating: English-only word forms in v1, digits locale-agnostic, shared verbatim by the watch (no platform imports allowed in this file).
- [ ] **Step 4: Run `swift test` — expect PASS.** Commit — `git commit -m "feat(kit): SpokenAnswerParser — spoken token/number parsing (refs #17)"` → push.

### Task 3: App — transcription engine (SpeechAnalyzer primary, SFSpeechRecognizer fallback, scripted mock)

**Files:**
- Create: `App/Sources/Voice/SpeechTranscribing.swift` (protocol + resolver), `App/Sources/Voice/SpeechAnalyzerEngine.swift`, `App/Sources/Voice/SFSpeechFallbackEngine.swift`, `App/Sources/Voice/MockSpeechEngine.swift`
- Delete: `App/Sources/Voice/SpeechSpikeView.swift` (spike harness retired)
- Test: engine-selection + mock-scripting unit tests in the app test target (no live audio in tests, ever)

**Interfaces (produced — Task 4 relies on these exact names):**
- `protocol SpeechTranscribing` — `func start() async throws -> AsyncStream<TranscriptionUpdate>`, `func stop() async`, where `TranscriptionUpdate { text: String, isFinal: Bool }`
- `enum SpeechEngineResolver { static func resolve(locale: Locale, isTestEnvironment: Bool) async -> (any SpeechTranscribing)? }` (nil = hide the mic button)

- [ ] **Step 1: Resolver + mock, test-first.** Tests: test environment → mock, always; scripted mock replays a volatile/volatile/final sequence; resolver returns nil when both engines report unavailable (inject availability probes as closures so tests never touch Speech).
- [ ] **Step 2: SpeechAnalyzerEngine** per the spike's recorded shape: AVAudioEngine input tap → `AsyncStream<AnalyzerInput>` (format converted via the module's `availableCompatibleAudioFormats`), `SpeechTranscriber(locale: supportedEquivalent, preset: <spike's answer>)`, `SpeechAnalyzer(modules: [transcriber])`, `start(inputSequence:)`, consume `transcriber.results` mapping to `TranscriptionUpdate(text: String(result.text.characters), isFinal: result.isFinal)`; `stop()` calls `finalizeAndFinishThroughEndOfInput()` and tears down the tap + audio session (`.notifyOthersOnDeactivation`). First-use asset flow: `AssetInventory.status` → if `.supported`, run `assetInstallationRequest(...).downloadAndInstall()` surfacing progress through the stream (a `TranscriptionUpdate` with a `downloading` phase or an engine-state callback — pick during implementation, record); `reserve(locale:)` per the spike finding.
- [ ] **Step 3: SFSpeechFallbackEngine** — `SFSpeechAudioBufferRecognitionRequest` with `requiresOnDeviceRecognition = true` (assert + test the configuration), `shouldReportPartialResults = true`, same AVAudioEngine tap, mapping partial/final to the same stream. Both engines share the tap/session helper — one place owns `AVAudioSession` (category `.record`, mode `.spokenAudio`, per the spike's session-collision finding).
- [ ] **Step 4: Verify** — app unit tests green, `xcodebuild build-for-testing`. Commit — `git commit -m "feat: on-device speech engines — SpeechAnalyzer + SFSpeechRecognizer fallback (refs #17)"` → push.

### Task 4: App — inline mic button + live transcript in the survey

**Files:**
- Create: `App/Sources/Voice/VoiceInputBar.swift` (mic button + volatile-transcript strip)
- Modify: `App/Sources/Survey/QuestionPageView.swift` (mount the bar on `tokens`/`people`, `note`, `location`, and `number` `.textField` inputs)
- Test: UI-test flows using the mock engine

- [ ] **Step 1: VoiceInputBar.** States: idle (mic glyph) / recording (stop glyph, pulsing, volatile text dimmed in the strip) / unavailable (view not mounted — resolver returned nil). Tap starts the resolved engine; final updates flow to a per-question-type commit closure; tap-again stops; page swipe/disappear stops AND flushes (join the existing `PendingFlushRegistry` so DONE/swipe mid-utterance finalizes rather than drops — same never-lose-text contract the keyboard fields honor). Speech authorization denied at tap time → inline "enable in Settings" hint, never a dialog.
- [ ] **Step 2: Type-aware commits.** tokens/people: each final segment → `SpokenAnswerParser.tokens` → append via `onChange(tokens + parsed)` respecting the existing last-token dedupe; note/location: final text appends into the field's draft through the existing debounced path; number: `SpokenAnswerParser.number` → `onAnswer(.number(parsed))`, unparseable → transcript stays visible + haptic, nothing committed.
- [ ] **Step 3: Wire into `QuestionPageView`** for the five surfaces; non-text number styles and choice questions get nothing. Accessibility per the Global Constraints bar.
- [ ] **Step 4: UI tests (mock engine):** token question — mic tap, scripted "coffee, toast and eggs" final → three chips appear; number question — scripted "about seven" → field shows 7; stop-on-swipe flush; mic button ABSENT under a resolver-nil launch argument.
- [ ] **Step 5: Verify** — suites + UI flows green. Commit — `git commit -m "feat: voice answers — inline mic + live transcription in survey (refs #17)"` → push.

### Task 5: Permissions cascade + Info.plist strings + privacy policy

**Files:**
- Modify: `App/Sources/Privacy/PermissionCascade.swift`, `project.yml`, `docs/privacy-policy.md`

- [ ] **Step 1: Cascade.** Add `requestSpeech()` (continuation + `OneShotResumeGuard`, `SFSpeechRecognizer.requestAuthorization`) sequenced after `requestMicrophone()` in `requestAll()`; add the `permissions.speechRequested` upgrade top-up alongside `runUpgradeTopUpIfNeeded()`'s existing steps (flag written BEFORE the step — the crash-tolerance comment pattern; one attempt, Settings → Request Sensor Access remains the retry path). Test-environment bypass inherited from the cascade gate.
- [ ] **Step 2: project.yml.** Add `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` ("Dispatch transcribes your voice on this device to fill in answers when you tap the microphone. Audio is never stored or sent anywhere."); REWRITE `INFOPLIST_KEY_NSMicrophoneUsageDescription` to cover both uses (ambient decibel sampling + voice answers, on-device, nothing recorded).
- [ ] **Step 3: Privacy policy** per the design decision above: scope the ambient-sound bullet, add the Voice answers bullet, disclose the Apple model-asset download under Apple services. Keep the blunt register the document uses.
- [ ] **Step 4: Verify** — cascade unit behavior where testable, build, manual cascade run on a fresh install (device) confirming dialog order and the top-up on an upgraded install. Commit — `git commit -m "feat: speech permission in onboarding cascade + privacy policy voice answers (refs #17)"` → push.

### Task 6: Watch — dictation confirmation for token answers

**Files:**
- Modify: `Watch/Sources/WatchQuestionView.swift` (textControls / textValue)
- Test: kit parser already covers splitting; watch build + on-device/simulator dictation flow check

- [ ] **Step 1: Parse + confirm.** For `tokens`/`people` questions: after the dictated `text` is non-empty, render `SpokenAnswerParser.tokens(from: text)` as removable chips (reuse the chip pattern, watch-sized) with the File button reading "File 3 items"; File commits `.tokens(parsedRemaining)`. `note`/`location` keep today's direct pass-through filing. The single-utterance = single-token bug (`textValue`'s `.tokens([trimmed])`) dies here.
- [ ] **Step 2: Accessibility + verify** — chips labeled/removable via VoiceOver; watch scheme builds; file a multi-token dictated answer in the simulator and confirm the phone report detail shows the split tokens post-sync. Commit — `git commit -m "feat(watch): dictated token answers split + confirmed before filing (refs #17)"` → push.

### Task 7: Wrap + tier-2 follow-up + self-review

- [ ] File the tier-2 follow-up issue ("Hands-free voice filing: Siri/App Intents parameter-resolution dialogs + Action button", referencing #17, this plan, and the spike findings — note that `QuickAnswerIntent`/`AppActions` in `App/Sources/Intents/` are the integration points and that parameter resolution gives Siri-native voice capture for free, no Speech code needed). Tier 2 was deliberately cut from this plan: it shares zero code with tier 1's transcription engine and stands alone cleanly.
- [ ] Full suites green (`swift test`, app build-for-testing, UI suite at the merge gate, watch scheme); note test-count delta from the previous plan's final report.
- [ ] Self-review the whole branch diff: (a) `requiresOnDeviceRecognition = true` pinned + asserted; (b) no audio ever written to disk (grep the Voice/ directory for file APIs); (c) spike harness deleted; (d) mic/speech never touched under `--mock-sensors`/`--ui-testing`; (e) privacy policy and purpose strings tell the same story; (f) accessibility identifiers `voice-input` + transcript labels present; (g) spike findings section filled and cited in code comments.
- [ ] Completion note in this doc (what shipped, divergences, test counts, the spike's answers). Whole-branch review follows (controller-driven). Do NOT close #17 (it covers all three tiers); comment on it with tier-1 status + the follow-up issue link.
