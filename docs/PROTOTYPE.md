# LectureClipDemo — Quick Export + Advanced Export

Native SwiftUI iPadOS **27+** proof of concept. Uses only Apple frameworks (no subscriptions).

## Workflows

- **Quick Export + Copy:** A single tap seals the current audio chunk, exports the interval `[last successful quick export end, current audio end)`, and places transcript text and M4A audio on the pasteboard. No picker or confirmation. The cursor advances **only if export succeeds**. The first quick export captures everything from recording start; successive exports capture only new audio. Each new recording resets the cursor.
- **Advanced Export:** Two sliders select arbitrary start/end times. As either slider moves, matching timestamped words highlight, preview text updates, and transcript scrolls near the changed endpoint. Press Export to create/copy that selected interval. Advanced exports do **not** advance the Quick Export cursor.
- Each export additionally stores a `.m4a` and `.txt` under Documents/Exports. Last clip can be shared using the standard share sheet if clipboard paste is not supported by a destination app.
- Microphone capture uses `AVAudioEngine` + iPadOS 27 `installAudioTap` to enqueue immutable buffers. The disk queue writes 5-second CAF/PCM chunks. Export seals the active chunk **without stopping** the engine; AVFoundation combines only finalized chunks into an M4A.

## Critical caveats

1. **Not connected to ASR yet:** The "Add example transcript words" button creates placeholder words with *approximate* times. Connect a real speech recognizer to `receiveFinalWords`, supplying individual word-level timestamps aligned to the audio sample clock. Without accurate word timings, live text and advanced selection cannot be exact.
2. **Paste destination limitations:** The Quick Export puts *two pasteboard items* (plain text + M4A file) without opening a share sheet, but each receiving app decides which item(s) it will accept. Some will paste text only; others won't paste audio at all. Use **Share last clip** or save into Files as a fallback. Copying the file does not guarantee Goodnotes can paste the audio.
3. **Instantaneous is aspirational:** Audio conversion/encoding is asynchronous and takes time (usually a short delay). UI shows "Exporting..." while processing; it never blocks audio recording.
4. **Background inference:** `UIBackgroundModes=audio` supports legitimate background microphone recording. It does **not** guarantee Parakeet, live ASR, or local summarization will run when the app is backgrounded. These may need to catch up when foregrounded.
5. **Not production-ready:** Error recovery, crash persistence, session interruptions, format changes, long-session CPU/battery tests, queue backpressure, disk retention, and real ASR are outstanding. Audio samples are measured in frames; live UI/demo elapsed-time is approximate. Work from recorded sample timestamps, not `Date()`, for production alignment.
6. **Privacy:** Audio and exported text remain on device unless you explicitly share them. Seek instructor permission before recording lectures.
7. **SDK availability:** This project intentionally targets iPadOS 27 because `installAudioTap` with `AVReadOnlyAudioPCMBuffer` is a newer API. To support iPadOS 26, substitute the older `installTap` with an owned copy of each incoming PCM buffer before dispatching it off the real-time thread.

## Run on iPad

1. Install Xcode with iOS 27 SDK plus XcodeGen from https://github.com/yonaskolb/XcodeGen.
2. From the extracted folder, run `xcodegen generate` and `open LectureClipDemo.xcodeproj`.
3. In Xcode Signing & Capabilities, select your Apple team and unique bundle identifier. Verify Background Modes includes audio.
4. Run on a physical iPadOS 27 iPad. Grant microphone access.
5. Tap Start Recording, speak for 10 seconds, Add example transcript words, then Quick Export. Wait 10 more seconds and Quick Export again; the second audio file should contain only that later interval.
6. Tap Advanced Export and drag both sliders. Text highlights and auto-scrolls. Export. Use Share last clip to verify both files.

## Structure

- `Models.swift` — transcript words, chunk metadata, export types
- `SegmentedAudioRecorder.swift` — continuous capture, chunk sealing, snapshot
- `ClipExporter.swift` — compose any requested range into M4A + TXT
- `ClipClipboard.swift` — no-modal, multi-item clipboard
- `ContentView.swift` — recording, quick export cursor, advanced sliders, scrolling preview
- `LectureClipDemoApp.swift` — SwiftUI app

## API references

- https://developer.apple.com/documentation/avfaudio/avaudionode/installaudiotap(onbus:buffersize:format:tapprovider:)
- https://developer.apple.com/documentation/avfaudio/avaudiofile/close()
- https://developer.apple.com/documentation/avfoundation/avassetexportsession
- https://developer.apple.com/documentation/uikit/uipasteboard/setitemproviders(_:localonly:expirationdate:)
- https://developer.apple.com/documentation/foundation/nsitemprovider/init(contentsof:)

Compilation against the Apple SDK and hardware recording tests have not been performed here.
