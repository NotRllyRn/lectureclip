# LectureClip

A native SwiftUI app for **iPhone and iPad, iOS/iPadOS 26+**. Record lectures, transcribe locally with Parakeet TDT V3, and export matching M4A audio and text for study notes.

## Run on your device

1. On a Mac, install full Xcode 26 or newer, open it and install the iOS SDK/simulator. Select it with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` if necessary.
2. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
3. Clone this repository, run `xcodegen generate`, then open `LectureClip.xcodeproj`.
4. Select your signing team for **LectureClip and LectureClipBroadcast**. Configure unique bundle IDs and a shared App Group (see System audio below). Connect your iPhone/iPad, enable Developer Mode if requested, select it as the run destination, and run.
5. Tap **Download / Retry Parakeet V3** while online. Model setup can take several minutes and substantial disk space. Once cached, recognition is local and the model reloads automatically on later launches. Recording works before model setup finishes.
6. Tap **New recording**, allow microphone access, and speak. The counter reports saved sample time, refreshed roughly every two seconds. Gray words are provisional. Stop to finalize the remaining transcript.

The full app uses an App Group and a broadcast extension, requiring an Apple Developer team with those provisioning capabilities. For microphone-only development with a Personal Team, remove the embedded LectureClipBroadcast dependency and App Group entitlement from the app target; system audio will be unavailable. This repository does not contain a signed IPA or TestFlight release.

## System audio from other apps

Select **System audio → Prepare system recording**, tap Apple's circular broadcast control, and confirm **Start Broadcast**. Then open Safari, Zoom, or your lecture app. Stop with the same broadcast control or the system recording indicator. Apple controls this visible consent flow; it cannot be replaced by a silent toggle. ReplayKit provides app-audio buffers; LectureClip discards video and microphone buffers. Protected content and some communication apps may block or omit audio.

Before installing on a physical device, register one App Group and enable it for **both targets** in Signing & Capabilities. The example identifiers are `com.notrllyrn.LectureClip`, `com.notrllyrn.LectureClip.Broadcast`, and `group.com.notrllyrn.LectureClip`. If changed, update `project.yml`, both `.entitlements` files, and `Sources/BroadcastState.swift` to match your registered identifiers. Both targets must use the same team.

The broadcast extension stores audio locally in the shared container; it never streams video/audio to a server. System-mode capture does not grant the main app continuous background execution for speech recognition. Return to LectureClip to catch up from saved audio. Pauses or periods without delivered audio do not advance the sample clock. Broadcast recording requires physical-device validation; a simulator launch test cannot prove cross-app capture.

## Export and recovery

- **Quick Export + Copy** exports from the previous successful Quick Export boundary to the current finalized transcript boundary. Silence also advances the boundary. Pending audio remains for the next export. A failed export leaves the cursor unchanged.
- **Advanced Export** selects any saved range without moving the Quick Export cursor. It can export audio whose transcript is still pending; the preview contains finalized words only.
- Both workflows save M4A/TXT files in Documents/Exports. Clipboard support depends on the receiving app; **Share clip** and **Copy text** are fallbacks. Goodnotes may not accept an audio clipboard item.
- The folder menu opens previous recordings. Relaunch recovers indexed, sealed CAF chunks and transcription/export progress. An unsealed tail can be lost on forced termination. Starting a new recording preserves prior sessions.
- Files are accessible through Files/Finder sharing. No automatic retention policy deletes lectures. Do not edit or remove active session files while recording.
- **Notes & titles** uses Apple Foundation Models when Apple Intelligence is available. Opening notes are generated automatically after about two minutes of finalized transcription, and the summary refreshes after stop/catch-up. Manual generation is also available.

## Architecture

`Core/` contains pure Swift timestamp and export rules. `SegmentedAudioRecorder` owns microphone capture and a bounded serial disk writer. `SessionStore` persists sealed chunk indexes separately from transcript metadata. `ParakeetTranscriber` owns FluidAudio and bounded 16 kHz mono conversion. `LectureStore` orchestrates one inference at a time, export, recovery and summaries. SwiftUI views expose these actions without model logic.

The rolling recognizer reads up to eight seconds of context, retains a two-second provisional tail, and schedules again after two seconds during recording. Backlogs are processed sequentially from disk. Timestamp overlap merging is a heuristic, not a claim of perfect word alignment. FluidAudio is pinned to a specific revision and explicitly loads `.v3`; changing it requires rebuilding and validation.

The legacy `installTap` API copies incoming PCM buffers before handing them to the writer. This avoids requiring the prototype's iOS 27-only `installAudioTap`. Chunks seal around five seconds, or earlier for snapshots. A bounded queue stops recording visibly on overflow instead of silently dropping data. Interruptions and input changes stop capture; start a new session to continue.

## Verification

- `swift test`: pure Swift timeline, selection, overlap, persistence, and export-boundary tests; no Apple mobile SDK required.
- `scripts/check-macos.sh`: core tests plus unsigned simulator/device SDK builds (requires Xcode and XcodeGen).
- GitHub Actions runs those checks, app launch/source-toggle tests, and a native PCM→CAF→M4A/TXT integration test on iPhone and iPad simulators.
- Live microphone UI testing is opt-in: add `LECTURECLIP_LIVE_MIC_TEST=1` to the Xcode scheme's Test environment variables on a host with working audio, or run on a physical device. It is explicitly skipped by default; passing offline audio tests is not proof of microphone capture.
- See [device acceptance tests](docs/TESTING.md) and [implementation plan](docs/PLAN.md).

Background audio mode supports active microphone recording. It does not guarantee continuous Core ML execution. Approximately five seconds of transcription delay is a target requiring physical-device measurement, especially with Goodnotes foregrounded. Microphone mode does not capture other apps' internal audio; System audio uses ReplayKit with explicit user consent. A simulator cannot establish battery, thermal, Neural Engine or sustained background behavior.

Audio and transcripts remain local unless shared. First model setup downloads model assets from FluidAudio's model host. Seek permission before recording lectures.

The supplied prototype's original documentation is preserved in [docs/PROTOTYPE.md](docs/PROTOTYPE.md).

## Free-account sideload IPA

On a Mac, run `scripts/package-sideload.sh` to generate `artifacts/LectureClip-Microphone-unsigned.ipa`. This Release build supports both iPhone and iPad on iOS/iPadOS 26+, hides System audio, makes no App Group requests, and omits the broadcast extension. Microphone recording, Parakeet, export and supported on-device summaries remain included. It contains no Apple signing certificate or provisioning profile.

Import the IPA into SideStore, AltStore, or Sideloadly and let that tool sign/install it using your own Apple account. Enter credentials only in your chosen tool. Free-account provisioning normally expires after seven days and must be refreshed; enable Developer Mode/trust the developer profile if iOS requests it. Installation and live capture still need verification on your physical devices. The full Xcode project retains ReplayKit support for a team with App Groups provisioning.


## Download builds from GitHub

- **Latest version:** [download the IPA](https://github.com/NotRllyRn/lectureclip/releases/latest/download/LectureClip-Microphone-unsigned.ipa) or browse [all releases](https://github.com/NotRllyRn/lectureclip/releases).
- **Every successful CI build:** open [iOS checks](https://github.com/NotRllyRn/lectureclip/actions/workflows/ios.yml), select a completed run, and download its `LectureClip-<version>-build-<build>-<run ID>` artifact. Unzip it to get the IPA and SHA256SUMS. GitHub requires signing in to download Actions artifacts; these are retained for 90 days.

CI packages the microphone-only Release IPA after core checks and iPhone/iPad simulator checks pass. Failed checks do not publish an installable build. Versioned releases retain their assets independently of the Actions artifact retention period.

To publish a new version, update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, commit, then push a matching version tag (for example, `git tag v1.0.4 && git push origin v1.0.4`). The workflow verifies that the tag matches the built app version and publishes the IPA plus its checksum to GitHub Releases. Use a new version tag for each release; existing release assets are not silently replaced. Regular pushes and manual workflow runs still provide artifacts without a release tag.

## Recording names and automatic notes

Use the pencil beside the current recording's name to **Name / Rename recording** or **Regenerate recording title**. The recording date and time remain visible under the name and in Saved lectures. Manual names are preserved when automatic notes finish generating.

With Apple Intelligence enabled and its model available, LectureClip automatically creates an opening title and summary after approximately two minutes of finalized transcription. It refreshes the summary once recording stops and transcription finishes; shorter recordings get their first notes then. Automatic generation starts while the app is active, and resumes checking when you return. It does not wait for notes to finish before allowing you to stop recording. Summaries show which transcript timestamp they cover.

Open **Notes & titles → Generate / Refresh notes** to generate notes sooner, refresh them, or retry a failure. Without Apple Intelligence, recording, transcription, exports, and manual naming continue to work. Generated titles and summaries should be checked for accuracy.

New exports appear under **Saved clips** for their lecture, including after relaunch. Select a clip, then use **Notes & titles → Regenerate clip title** to generate a name from that clip's transcript and rename its M4A/TXT files. Clips exported before this feature remain available in Files → LectureClip → Exports.
