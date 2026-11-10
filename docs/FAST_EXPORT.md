# Fast audio export

## Design
- Preserve PCM chunks and `chunks.json` as the authoritative recording/transcription source. This update improves export latency; it does not delete original recordings to save space.
- Feed sealed chunks into **one continuous mono 48 kHz, 64 kbps AAC encoder**, on a serial utility queue. Independent AAC files introduce encoder priming at every join and are not a reliable gap-free export source.
- The encoder writes a fragmented QuickTime cache with one-second fragment intervals. Container fragments do not restart the encoder. Timestamp buffers from an integer frame clock; normalize each source-rate boundary to the absolute recording timeline.
- Capture never waits for encoding. Admission is bounded; each admitted snapshot contains the full chunk index, so the next job catches up on any skipped chunks. Only one session's cache is retained per process.
- Export takes an immutable APFS clone (copy fallback), validates the audio track's available range, then trims the single continuous asset into a standalone M4A using passthrough. No decoding/re-encoding is needed for a warm, covered selection.
- Submitted PCM is not necessarily flushed media. Briefly retry an incomplete live snapshot (at most 300 ms), then fall back to PCM if the requested tail is unavailable. Never silently truncate audio or advance the export cursor past missing audio.
- Stopped exports finalize the encoder to include its exact tail. Resuming after finalization rebuilds the cache once from PCM. Repeated exports from an unchanged finalized cache reuse it.
- The fallback normalizes bounded PCM windows and uses a separate, explicit 64 kbps AAC encoder; it does not evict the warm live cache.
- The main app owns the cache. The broadcast extension only writes PCM; the app prewarms its cache as it observes shared recording snapshots. If the app was suspended during a broadcast, it must catch up on first export.
- Cache snapshots are removed after export. The active temporary cache is removed on session switch/deletion; stale temporary files from an interrupted process are cleaned on next cache use. Existing exported files are never mutated.

## Validation
Apple-platform integration tests cover:
- AAC codec, mono format, 64 kbps target, and duration;
- decoded audio continuity across source chunks and sample-rate changes;
- live snapshots, finalized output, non-packet-aligned cuts, and a 25 ms selection;
- an unavailable live tail through the public fallback path;
- finalized-cache reuse and rebuilding after resume;
- cancellation recovery, missing audio, and a warm two-minute export.

The initial independent-segment prototype was rejected by these tests: M4A passthrough failed with -11838/-16976, while an MP4 workaround inserted silence at joins. The continuous encoder replaces that design rather than weakening the continuity assertions.

## Limits
The cache adds about 29 MB/hour plus container overhead while preserving PCM. File export still scales with selected compressed bytes; instant export is not guaranteed. Cold sessions, app relaunch, broadcast catch-up, resume after finalization, or an unflushed tail can require encoding. Long-duration background behavior, receiving-app compatibility, battery/thermal impact and latency on an actual iPad still require device acceptance testing.
