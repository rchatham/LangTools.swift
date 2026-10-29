//
//  RealtimeView.swift
//  LangTools_Example
//
//  Realtime voice interface: live speech-to-speech conversation with the
//  OpenAI Realtime API, with streaming transcripts, barge-in interruption,
//  and an optional text input.
//

import SwiftUI

public struct RealtimeView: View {
    @StateObject private var viewModel: RealtimeSessionViewModel
    @Environment(\.dismiss) private var dismiss

    public init(apiKeyProvider: @escaping () -> String?) {
        _viewModel = StateObject(wrappedValue: RealtimeSessionViewModel(apiKeyProvider: apiKeyProvider))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                Divider()
                transcriptList
                Divider()
                controls
            }
            .navigationTitle("Realtime Voice")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        Task {
                            await viewModel.disconnect()
                            dismiss()
                        }
                    }
                }
            }
            .onDisappear {
                Task { await viewModel.disconnect() }
            }
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(viewModel.connectionState.rawValue)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if viewModel.isUserSpeaking {
                Label("Listening", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if viewModel.isModelSpeaking {
                Label("Speaking", systemImage: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.transcript.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.transcript) { entry in
                        transcriptRow(entry)
                            .id(entry.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.transcript) { _, entries in
                if let last = entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(viewModel.connectionState == .connected
                 ? "Start talking — the assistant is listening."
                 : "Connect to start a live voice conversation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func transcriptRow(_ entry: RealtimeSessionViewModel.TranscriptEntry) -> some View {
        HStack {
            if entry.role == .user { Spacer(minLength: 40) }
            VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 2) {
                Text(entry.role == .user ? "You" : "Assistant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        entry.role == .user
                        ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                        : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .opacity(entry.isFinal ? 1 : 0.6)
            }
            if entry.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.connectionState == .connected {
                MicLevelBar(mic: viewModel.mic, isUserSpeaking: viewModel.isUserSpeaking)

                HStack(spacing: 10) {
                    TextField("Type a message…", text: $viewModel.textInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await viewModel.sendTextMessage() } }
                    Button {
                        Task { await viewModel.sendTextMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(viewModel.textInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack(spacing: 16) {
                connectButton
                if viewModel.connectionState == .connected && viewModel.isModelSpeaking {
                    Button(role: .destructive) {
                        Task { await viewModel.interrupt() }
                    } label: {
                        Label("Interrupt", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
    }

    private var connectButton: some View {
        Button {
            Task {
                if viewModel.connectionState == .connected {
                    await viewModel.disconnect()
                } else {
                    await viewModel.connect()
                }
            }
        } label: {
            Label(
                viewModel.connectionState == .connected ? "End Session" : "Start Session",
                systemImage: viewModel.connectionState == .connected ? "phone.down.fill" : "phone.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.connectionState == .connected ? .red : .accentColor)
        .disabled(viewModel.connectionState == .connecting)
    }
}

// MARK: - Mic Level Bar

/// Separate child view so it observes the mic streamer directly — level
/// changes publish on the streamer, not the session view model.
private struct MicLevelBar: View {
    @ObservedObject var mic: RealtimeMicStreamer
    let isUserSpeaking: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(isUserSpeaking ? Color.green : Color.accentColor)
                    .frame(width: max(4, geo.size.width * CGFloat(mic.audioLevel)))
                    .animation(.linear(duration: 0.1), value: mic.audioLevel)
            }
        }
        .frame(height: 6)
    }
}
