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
