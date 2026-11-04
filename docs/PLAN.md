# Implementation plan

## Scope and decisions

Build one SwiftUI app for iPhone and iPad, with iOS 26 as the minimum. Use the established AVAudioEngine installTap API and copy callback buffers before asynchronous disk access; this also runs on iOS 27 without requiring its new audio API. Keep the supplied prototype documentation in PROTOTYPE.md. No original prompt history was included in the ZIP.

1. Import the supplied prototype and preserve its workflows.
2. Separate sample-clock recording, durable session storage, recognition, and screen state.
3. Pin FluidAudio to a reviewed source revision and explicitly select Parakeet TDT V3. Read bounded windows from sealed CAF files, convert to 16 kHz mono, and run one inference at a time. Advance sequentially through a backlog instead of skipping audio. Preserve a provisional tail and commit by timestamp.
4. Persist finalized words, recognition progress, and the successful Quick Export cursor. Recover sealed chunks after relaunch; never assume a crashed open CAF is complete. Stop on capture interruptions and make restart explicit.
5. Keep Quick Export aligned with finalized audio; Advanced Export may include audio awaiting transcription. Keep M4A/TXT share fallback. Offer on-demand Foundation Models summaries with availability checks.
6. Add pure Swift timeline tests and macOS CI build checks. Validate recording/export on both device families and benchmark on physical hardware when available.

## Ownership

- ChunkWriter: serial disk queue, bounded pending buffers, sealed chunk index.
- SegmentedAudioRecorder: main-actor AVAudioSession and engine lifecycle.
- SessionStore: atomic session metadata; independent from audio chunk index.
- ParakeetTranscriber: actor owning model inference and bounded file reads.
- TranscriptTimeline: pure timestamp merge and export-boundary rules.
- LectureStore: main-actor orchestration, one inference task, persisted UI actions.
- Views: adaptive system controls, transcript selection, sharing.

## Failure behavior

Audio capture does not wait for model download or inference. Disk errors and queue overflow stop recording visibly rather than silently losing audio. ASR errors leave the durable cursor unchanged and expose retry. Sealed audio survives termination; an unsealed tail may be lost. No automatic deletion of recordings. Export advances the cursor only after both files are written and session state is persisted.

## Validation constraints

Initial inspection: this Linux host had neither Swift nor Xcode, and T3 device_open(platform: ios) returned: “Agent device access is turned off for this environment.” A Mac was subsequently connected over SSH and Xcode installed. See TESTING.md for executed native checks and remaining physical-device requirements. Five-second delay, Goodnotes background behavior, clipboard compatibility, battery, thermal and memory behavior are acceptance tests, not guarantees.

## Added scope: system audio

User requested a microphone/system-audio toggle and confirmed capture from other apps. Use ReplayKit's broadcast upload extension with an explicit system broadcast picker; AVAudioEngine cannot capture another app's output. The extension writes only audioApp PCM buffers through the shared bounded ChunkWriter. It discards video and audioMic buffers, publishes a heartbeat and seals audio into an App Group. The main app reads shared chunks and catches up transcription when it can execute. Model inference never runs in the memory-limited extension. System broadcast controls stop capture; there is no hidden programmatic start/stop. Stale heartbeats expose saved data after interrupted broadcasts.
