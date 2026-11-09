# Fast audio export

## Scope
Pre-encode sealed recording chunks as mono 48 kHz AAC at 64 kbps. Export by composing immutable AAC segments with passthrough instead of normalizing and encoding the entire selection at tap time. Keep PCM as the authoritative recording/transcription source in this first change: deleting it safely is a separate storage migration, not required for faster export.

## Design
- A small shared cache module owns serial encoding, bounded admission for capture and exports, atomic publication, and lazy regeneration. Capture never waits for encoding; exports wait cooperatively and can cancel between conversion buffers. Invalid caches are rebuilt. Cache files live beside their source and are removed with the lecture.
- ChunkWriter schedules encoding only after closing and indexing a chunk. Both microphone and broadcast use this path.
- Export fills missing cache entries, checks continuous coverage, and composes the requested time ranges into a standalone M4A using passthrough. Existing PCM export remains a fallback for codec/container failures. Cancellation is not retried.
- Original frame indices and Quick Export cursor semantics remain unchanged. Never concatenate raw M4A bytes or mutate files already shared.
- Reduce fallback scanning by passing only intersecting chunks to each window reader.

## Verification
Add Apple-platform integration tests for AAC format/bitrate, multi-chunk partial-range export, missing audio, cache reuse and missing-cache regeneration. Test on a physical device: 60–90-minute recording, background/broadcast capture, interruptions, AAC segment joins (priming/padding), partial cuts, export duration, and wall-clock latency. Linux cannot execute AVFoundation tests.

## Tradeoffs
The cache temporarily adds roughly 29 MB/hour rather than reducing PCM storage. Legacy recordings encode on first export. Background backlog and file copying mean latency is not guaranteed instant. Independent AAC segments require device validation for audible joins and edit-list handling by receiving apps. The legacy PCM fallback retains Apple's M4A preset rather than guaranteeing 64 kbps; the prepared cache/passthrough path explicitly requests 64 kbps.
