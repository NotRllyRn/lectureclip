# Device acceptance tests

Run on both iPhone and iPad. Core tests and simulator launch tests do not validate capture or inference hardware.

1. Fresh install: deny microphone permission, verify a readable error; enable permission in Settings and retry. Record without downloading the model and verify saved audio is available through Advanced Export.
2. Download V3, record known speech for 30 seconds, stop, wait for catch-up. Check actual words and timestamps against playback; do not substitute generated example text.
3. Quick Export twice during recording and once after stopping. Play the clips in order: no missing/duplicate interval, each text matches its audio. Try during initial recognition lag: it must wait for a finalized boundary. Export silence as well.
4. Advanced Export: drag both endpoints, verify highlighted words, export across several chunk boundaries, and confirm the Quick Export cursor is unaffected. Test portrait, landscape, iPhone compact width, iPad split view and large text.
5. Paste into Goodnotes; separately test the system share sheet for audio and text. Destination behavior is not controlled by this app.
6. Stop and relaunch; recover transcript and Quick Export cursor. Force-terminate while recording, relaunch and verify all indexed sealed chunks are playable. The unsealed tail is not guaranteed. Open an older session and catch up its transcription.
7. Interrupt via phone call, change input route, lock/unlock the screen, disconnect headset, and exhaust storage on a test device. Verify recording stops visibly on capture failures and saved chunks remain accessible.
8. Disable network after model setup: record/transcribe/export offline. Disable Apple Intelligence and verify the summary availability message; enable it and compare summaries to finalized transcript.
9. On iPad Air M2, run 60–90 minutes with Goodnotes foregrounded. Measure audio continuity, median/p95/max transcript lag, recovery time, peak resident memory, thermal state and battery delta using Instruments. Repeat locked-screen and foreground baselines. Record OS/model versions and results below.

## Execution record

2026-11-04:

- Seven pure Swift timeline tests passed in GitHub Actions.
- Xcode 27.2 on the connected Mac built the app and ReplayKit extension for both iOS Simulator and unsigned iOS device targets.
- iPhone 18 Pro / iOS 27.2: three native tests passed (launch, source toggle, durable audio/export); one opt-in live microphone test skipped.
- iPad Air 13-inch (M4) / iOS 27.2: the same three native tests passed; one opt-in live microphone test skipped.
- The audio integration test generated six seconds of PCM, wrote/reloaded six CAF chunks, exported a 3.5-second M4A/TXT selection, decoded the M4A, checked selected text, and rejected a missing chunk.
- A live microphone attempt on the Mac simulator failed inside Apple AudioToolbox's `_ReportRPCTimeout` / `AURemoteIO::Initialize` when opening the input node. Denied permission was also handled visibly. Live capture is not marked passed.
- T3 `device_open`/`device_list` returned “Agent device access is turned off for this environment.” Native testing used Xcode/Simulator over the authorized SSH connection instead of the T3 Device panel.
- Real Parakeet inference/accuracy/latency, Foundation Models output quality, cross-app ReplayKit capture, physical-device recording, Goodnotes paste behavior, and 60–90-minute endurance remain unverified.

To opt into the live microphone UI test, set `LECTURECLIP_LIVE_MIC_TEST=1` in the Xcode scheme's Test environment variables on a configured host/device. The default suite uses real file encoding/decoding with generated PCM and explicitly skips microphone hardware; it does not substitute a fake production recorder.

## System-audio acceptance tests (physical device required)

1. Provision the app and embedded broadcast extension with the same App Group. Select System audio, prepare, tap Apple's broadcast button and confirm Start Broadcast. Open Safari and play a non-protected lecture with known spoken content. Return, stop through the system controls, and verify actual exported audio and transcript.
2. Speak near the device while recording system audio; verify the microphone is excluded. Conversely, select Microphone and verify it uses the microphone recording path.
3. Confirm video is never stored and the extension does not download/load Parakeet. Test protected content separately; silence or unavailable audio is expected where iOS blocks capture.
4. Cancel the broadcast-start sheet, cancel setup in the app, then select Microphone. Check that a stale prepared request cannot silently start a recording.
5. Test pause/resume, route/format changes, extension termination, app relaunch during a live broadcast, and re-opening after more than 15 seconds without a heartbeat. Saved sealed chunks must remain exportable.
6. Run the 60–90-minute endurance test with the lecture app foregrounded. System capture does not keep the main app alive for continuous ASR, so measure foreground catch-up separately from microphone-background latency.

## 1.0.1 recording-start fix

A user reported immediate termination on iOS 27.0 / iPhone 17 Pro Max with the built-in microphone. The provided attachment was the original 1.0 IPA, not an Apple crash report, so the device's exact termination reason remains unconfirmed.

Compiler inspection found that the original tap closure inherited MainActor isolation from `SegmentedAudioRecorder.start`. Its generated code called `_checkExpectedExecutor` before writing audio, although AVAudioEngine delivers the callback on its audio thread. The callback now comes from an explicitly Sendable, nonisolated factory on ChunkWriter. Generated code confirms the actor check is gone. Buffer copying also uses the valid frame byte count and checks source/destination bounds.

The native regression test invokes the exact installed callback from a detached task, with spare buffer capacity in interleaved and non-interleaved stereo formats. Both cases passed, including persisted duration and sample-value checks; the existing CAF/M4A/TXT integration test also passed. A physical-device retest of build 2 is still required.

To report a crash: Settings → Privacy & Security → Analytics & Improvements → Analytics Data → latest LectureClip entry → Share → Save to Files, then attach that `.ips` file. An IPA is an installer, not a log. If no LectureClip entry exists, check the nearest JetsamEvent entry for LectureClip (memory termination); share only the relevant report, not the entire analytics archive.

## 1.0.2 saved-audio reader fix

The user confirmed build 2 no longer crashes when recording starts, but transcription pauses with “Recorded audio is missing near 0.00 seconds.” A native reproduction demonstrated AVAudioFile returning 95,232 frames for a 95,488-frame request from a complete 48 kHz PCM file; the remaining 256 frames were available on the next read. The old transcription path incorrectly required a single read to fill the buffer.

AudioWindowReader now accumulates short reads before resampling, computes frame boundaries independently, and reports premature EOF or inconsistent file metadata separately from a missing timeline interval. The model-independent regression checks every stereo sample at zero and nonzero offsets, reads/resamples six-second windows across sealed chunks at 48 kHz and 44.1 kHz, and rejects actual gaps and truncated files. All three audio pipeline tests passed on the iPad simulator (Debug) and iPhone simulator (Release with ENABLE_TESTABILITY=YES) with Xcode 27.2. Physical-device Parakeet transcription still requires retesting; no device diagnostic report was supplied for this incident.

### Sharing runtime diagnostics

A handled transcription error does not normally create an Apple crash report. In LectureClip 1.0.2 or later, open the stethoscope (Diagnostics) menu, choose **Prepare diagnostics**, then reopen that menu and choose **Share diagnostics**. Save/share `LectureClip-diagnostics.txt`. A copy is also available in Files → On My iPhone/iPad → LectureClip → Diagnostics. Regenerate after reproducing an issue to capture the current session.

The report contains the app/OS version, pipeline state, the last 80 status/error events (retained across launches), and saved chunk metadata compared with actual file lengths/formats. It does not attach audio or transcript content. Quick Export still waits for the finalized transcript boundary; Advanced Export can export saved audio while recognition is paused. Install the update over the existing app using the same SideStore account to preserve downloaded models and saved lectures.

## 1.0.3 live sentence layout

TranscriptView groups recognized words using Apple's sentence tokenizer, renders each sentence as a wrapping paragraph with one timestamp, and keeps provisional words lighter. The unfinished sentence grows as ASR updates arrive; punctuation/revisions determine sentence boundaries. ScrollViewReader follows the transcript end on word updates, including revisions with unchanged word counts, and respects Reduce Motion. Recognition still delivers batches; the UI does not add a typing delay.

The iPhone simulator launch check passed. A populated simulator session was visually inspected for sentence wrapping, abbreviation handling (Dr. Rivera), provisional styling, and initial scrolling to the latest sentence. Live physical-device updates remain a user acceptance check. The unsigned device build supports both iPhone and iPad.

## 1.0.4 Advanced Export sentence layout

Live transcription and Advanced Export now share sentence grouping and row rendering. Advanced Export displays each sentence's time range and highlights only words overlapping the selected audio interval, including partial sentences. Moving the start/end sliders scrolls to the corresponding sentence; the exclusive end boundary stays on the preceding sentence when it exactly equals the next sentence's start. Audio trimming and transcript inclusion rules are unchanged.

The updated views compile for the iPhone simulator. T3 device access remains disabled, so interactive slider validation on a physical device remains an acceptance check.

## 1.0.5 names and automatic notes

Session metadata adds optional title, manual-title flag, summary coverage, and clip history fields so existing recordings remain decodable. New exports persist their title and selected transcript; their sandbox-relative filenames are rebased when a session reloads. Retitling copies the export pair before saving new references, rolls back new files on save failure, and removes the old pair after a successful save.

Automatic generation uses only finalized words. It runs once around 120 seconds of finalized audio, then refreshes after stop/catch-up; short recordings are eligible at completion. One pending/generating operation prevents overlapping language-model jobs, and per-session attempt tracking prevents failure loops. Automatic starts require foreground activity. Generation merges into fresh session metadata so in-flight ASR, export cursors, and manual renames are preserved. The user can retry/refresh manually. OnDeviceIntelligence wraps Foundation Models; a test implementation verifies coordination without requiring Apple Intelligence on the simulator.

Physical-device acceptance: enable Apple Intelligence, record speech for over two minutes, check opening notes/title and visible date; rename while generation runs and verify that the name stays; stop during generation and verify capture stops immediately, followed by a complete summary after ASR catches up. Export a clip, regenerate its title, share/play the newly named M4A, relaunch, reopen the lecture and select the saved clip. Repeat with Apple Intelligence unavailable and verify manual naming/audio still work. Test actual summary/title quality and memory/latency during sustained recording on device.

Validation: seven pure Swift core tests passed. Seven native iPad simulator tests passed (the three audio pipeline tests plus four metadata tests covering legacy decoding/manual names, two-minute/final-summary eligibility, merging a rename during generation, and clip retitling/path recovery). The iPhone simulator launch check passed. Tests use a stub language model for coordination; actual Apple Intelligence output quality and concurrent device resource use remain physical-device checks.

## 1.0.6 independent summary and background Quick Export

SummaryView has its own ScrollView and stable session identity; only TranscriptView observes word updates for programmatic scrolling. Switching back to Transcript follows the latest words.

The app UI and QuickExportIntent share one MainActor LectureStore, including the live recorder and export lock. Selected session IDs persist for cold launches. Model loading now occurs on foreground activation, so restoring state for an intent does not load Parakeet. The intent requests `.background` and returns `ReturnsValue<Bool>`; AppShortcutsProvider registers a parameterless action. No extension, App Group, or foreground-continuation capability is required for this action.

Clipboard copying checks write acceptance through change count and item count, without reading existing clipboard contents. Quick Export only saves its cursor after copying succeeds. If cursor persistence fails after copying, the exported files remain available to back the clipboard, and a retry may duplicate that interval rather than skip it. Errors from the shortcut go to diagnostics rather than an app alert.

Xcode's generated Metadata.appintents includes the discoverable QuickExportIntent, its Boolean output, `openAppWhenRun: false`, background mode, and the preconfigured shortcut phrase. Direct `perform()` tests validate application logic; they do not prove OS-routed Shortcuts execution while another app is foregrounded.

Physical-device acceptance: update through SideStore, confirm the action appears in Shortcuts, record known speech, open Goodnotes, run a personal shortcut containing the action, verify LectureClip stays in the background and the result is true, then paste/play the copied clip. Repeat immediately with no new finalized words (false), while locked (false if the action executes), after a cold app launch with a selected older lecture, with concurrent quick-export requests, and with a long pending export. Check that cold export does not download/load models, and that a failed export leaves the cursor unchanged. Read a long summary while speech is transcribed; its reading position must stay fixed.

Validation: seven pure Swift core tests passed; all nine native iPhone tests passed, including direct QuickExportIntent.perform() with real PCM → CAF → M4A → clipboard output, true/false results, failed-copy cursor preservation, concurrent-export exclusion, and cold selection/cursor recovery. The two shortcut tests and existing launch smoke test also passed on the iPad simulator. The first direct-intent test attempt was blocked by a previously seeded demo session generating notes; removing that owned demo fixture resolved the test setup conflict. OS-routed background invocation through Shortcuts on a SideStore-signed physical device remains unverified.
