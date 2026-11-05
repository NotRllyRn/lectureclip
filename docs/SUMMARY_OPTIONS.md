# Title and summary alternatives

The existing LectureIntelligence protocol separates title/summary generation from Parakeet speech recognition. Changing the summary provider does not require changing transcription. The current Foundation Models implementation sends one title request and one summary request per 6000-character chunk; long lectures can therefore trigger several consecutive generations. Its rate-limit error does not advance or stop the transcript cursor.

| Choice | Benefits | Tradeoffs |
| --- | --- | --- |
| Small local model via MLX Swift LM, initially Qwen3-1.7B 4-bit | Offline after download; transcript stays on the device; independent of Apple's model rate policy | Extra model download and RAM; GPU/thermal competition with Parakeet; must benchmark quality and iPad memory. Prefer foreground summaries after transcription catches up. |
| Model on the user's Mac through a local server such as Ollama | Larger model without loading the iPad; transcript can stay on the user's own machines | Mac must be awake and reachable; authenticated connection required; not standalone/offline away from the Mac. |
| Hosted model provider | Stronger long-lecture summarization without local inference memory | Transcript leaves device; internet, credentials, usage cost, and provider rate limits. Explicit opt-in before enabling. |
| Extractive notes and keyword titles | No model download or inference quota; lightweight and local | Selects source sentences instead of synthesizing explanations; lower-quality notes/titles. |

Recommendation for the original offline goal: prototype quantized Qwen3-1.7B through MLX, cap generation length, summarize bounded transcript sections, and run it after transcription catches up. Do not claim that simultaneous live ASR and LLM generation on an iPad Air M2 is validated. MLX is a runtime, not itself a summary model. Retain Apple Foundation Models as an optional provider until the alternative passes quality/memory tests.

FluidVoice (altic-dev) is a voice-to-text dictation application, primarily described for macOS in its README, with hotkey dictation, multiple speech engines, and optional text enhancement. Its separate Fluid Intelligence runtime provides local formatting/capitalization/post-processing and is described as privately maintained. It is not the same as FluidAudio, the speech library LectureClip already embeds, and its README does not provide a drop-in iOS lecture-summary SDK. The FluidVoice app's GPLv3 license and the separate runtime's licensing need to be considered before reusing code or assets. Do not assume its dictation-focused enhancement model is a long-lecture summarizer.

Sources checked 2026-11-05:
- https://github.com/altic-dev/FluidVoice
- https://github.com/ml-explore/mlx-swift-lm
- https://huggingface.co/mlx-community/Qwen3-1.7B-4bit
- https://huggingface.co/Qwen/Qwen3-1.7B
