//
//  OllamaSettingsView.swift
//  LangTools_Example
//
//  Created by Reid Chatham on 2/26/25.
//




import SwiftUI
import Ollama

struct OllamaSettingsView: View {
    @StateObject private var viewModel = ViewModel()
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ollamaService = OllamaService.shared
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Available Models")) {
                    if ollamaService.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if let error = ollamaService.error {
                        VStack(alignment: .leading) {
                            Text("Error loading models")
                                .foregroundColor(.red)
                            Text(error.localizedDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Retry") {
                                ollamaService.refreshModels()
                            }
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 8)
                    } else if ollamaService.availableModels.isEmpty {
                        Text("No models found")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(ollamaService.availableModels, id: \.rawValue) { model in
                            HStack {
                                Text(model.rawValue)
                                Spacer()
                                if viewModel.loadingModelName == model.rawValue {
                                    ProgressView()
                                } else if ollamaService.runningModels.contains(where: { $0.model == model.rawValue }) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.toggleModel(model)
                            }
                        }
                    }
                }
                
                Section(header: Text("Pull New Model")) {
                    HStack {
                        TextField("Model name (e.g. llama2)", text: $viewModel.newModelName)
                        if viewModel.isPulling {
                            ProgressView()
                        } else {
                            Button("Pull") {
                                viewModel.pullModel()
                            }
                            .disabled(viewModel.newModelName.isEmpty || viewModel.isPulling)
                        }
                    }
                    
                    if viewModel.pullProgress > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Downloading: \(Int(viewModel.pullProgress * 100))%")
                                .font(.caption)
                            ProgressView(value: viewModel.pullProgress)
                        }
                        .padding(.top, 4)
                    }
                    
                    if let pullError = viewModel.pullError {
                        Text(pullError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                Section(header: Text("Server Configuration")) {
                    HStack {
                        Text("Server URL")
                        Spacer()
                        Text(viewModel.serverUrl)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Ollama Settings")
            #if os(iOS)
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .listStyle(InsetGroupedListStyle())
            #endif
            .refreshable {
                ollamaService.refreshModels()
            }
            .onAppear {
                ollamaService.refreshModels()
            }
        }
    }
}

extension OllamaSettingsView {
    @MainActor class ViewModel: ObservableObject {
        @Published var loadingModelName: String? = nil
        
        // Pull model state
        @Published var newModelName: String = ""
        @Published var isPulling: Bool = false
        @Published var pullProgress: Double = 0
        @Published var pullError: String? = nil
        
        let serverUrl: String = "http://localhost:11434"  // This could be made configurable
        
        func toggleModel(_ model: Ollama.Model) {
            if OllamaService.shared.runningModels.contains(where: { $0.model == model.rawValue }) {
                // Model is already running, no need to do anything
                return
            }
            
            loadingModelName = model.rawValue
            
            Task {
                do {
                    try await OllamaService.shared.loadModel(model)
                    await MainActor.run {
                        self.loadingModelName = nil
                    }
                } catch {
                    await MainActor.run {
                        self.loadingModelName = nil
                        print("Failed to load model: \(error)")
                    }
                }
            }
        }
        
        func pullModel() {
            guard !newModelName.isEmpty, !isPulling else { return }
            isPulling = true
            pullError = nil
            pullProgress = 0
            
            Task {
                do {
                    try await OllamaService.shared.pullModel(newModelName) { [weak self] progress in
                        self?.pullProgress = progress
                    }
                    
                    await MainActor.run {
                        self.isPulling = false
                        self.newModelName = ""
                        self.pullProgress = 0
                    }
                } catch {
                    await MainActor.run {
                        self.isPulling = false
                        self.pullError = error.localizedDescription
                    }
                }
            }
        }
    }
}

#Preview {
    OllamaSettingsView()
}
