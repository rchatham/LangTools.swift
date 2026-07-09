# Realtime Module

A live voice interface for the example app built on the OpenAI Realtime API (`OpenAIRealtimeSession` from the LangTools `OpenAI` product).

## What it demonstrates

- **Speech-to-speech conversation**: mic audio streams up as PCM16 24kHz mono via `input_audio_buffer.append`; response audio streams back and plays as it arrives.
- **Server VAD turn-taking**: the session is configured with `server_vad` turn detection, so the model responds when you stop talking — no push-to-talk.
- **Barge-in interruption**: on `input_audio_buffer.speech_started` while the model is speaking, local playback is flushed immediately; a manual Interrupt button also cancels the active response and truncates the conversation item.
- **Live transcripts**: user speech transcription (`whisper-1`) and assistant audio transcript deltas render as a streaming conversation view.
- **Text input**: type a message into the same realtime session (`conversation.item.create` + `response.create`).

## Components

| File | Role |
|------|------|
| `RealtimeView.swift` | SwiftUI screen (status, transcript, mic level, controls) |
| `RealtimeSessionViewModel.swift` | Session lifecycle, event handling, interruption |
| `RealtimeAudio.swift` | `RealtimeMicStreamer` (tap → PCM16 24kHz chunks) and `RealtimePCMPlayer` (streaming playback with flush) |

## Access

Opened from the chat screen's toolbar (waveform icon). The OpenAI API key comes from the app's existing keychain storage (`KeychainService.shared.getApiKey(for: .openAI)`) — set it in chat settings first.
