//
//  OllamaSettingsView.swift
//  App
//
//  Created by Reid Chatham on 2/26/25.
//


import SwiftUI
import Ollama

// OllamaService extension to add connection checking and URL updating
extension OllamaService {
}

struct OllamaSettingsView: View {
    @StateObject private var viewModel = ViewModel()
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ollamaService = OllamaService.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isEditingServerUrl = false
    
    var body: some View {
        #if os(macOS)
        macOSLayout
            .frame(minWidth: 600, minHeight: 500)
            .background(colorScheme == .dark ? Color(.windowBackgroundColor) : Color(.textBackgroundColor))
        #else
        mobileLayout
        #endif
    }
    
    #if os(macOS)
    private var macOSLayout: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Ollama Models")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding([.horizontal, .top], 30)
            .padding(.bottom, 20)
            
            // Content
            ScrollView {
                VStack(spacing: 24) {
                    // Available Models Section
                    availableModelsSection
                    
                    // Pull New Model Section
                    pullNewModelSection
                    
                    // Server Configuration Section
                    serverConfigSection
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            ollamaService.refreshModels()
        }
    }
    
    private var availableModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Models")
                .font(.headline)
                .foregroundColor(.primary)
            
            Divider()
            
            if ollamaService.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.0)
                        .padding()
                    Spacer()
                }
            } else if let error = ollamaService.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Error loading models")
                        .foregroundColor(.red)
                        .font(.subheadline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        ollamaService.refreshModels()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                .padding(.vertical, 12)
            } else if ollamaService.availableModels.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "cube.box")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No models found")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    Spacer()
                }
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.fixed(120), alignment: .trailing)
                ], spacing: 12) {
                    // Header
                    Text("Model Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Status")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Divider
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 1)
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 1)
                    
                    // Model rows
                    ForEach(ollamaService.availableModels, id: \.rawValue) { model in
                        Text(model.rawValue)
                            .font(.subheadline)
                        
                        HStack {
                            if viewModel.loadingModelName == model.rawValue {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Loading...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if ollamaService.runningModels.contains(where: { $0.model == model.rawValue }) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Running")
                                    .font(.caption)
                            } else {
                                Button("Load") {
                                    viewModel.toggleModel(model)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        
                        // Divider after each row
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(height: 1)
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(height: 1)
                    }
                }
                .padding(.vertical, 8)
            }
            
            Button("Refresh Models") {
                ollamaService.refreshModels()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(.controlBackgroundColor) : Color.white)
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
        )
    }
    
    private var pullNewModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull New Model")
                .font(.headline)
                .foregroundColor(.primary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 16) {
                Text("Download a new model from Ollama library")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    TextField("Model name (e.g. llama2)", text: $viewModel.newModelName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(maxWidth: .infinity)
                    
                    if viewModel.isPulling {
                        Button("Pulling...") {}
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(true)
                    } else {
                        Button("Pull Model") {
                            viewModel.pullModel()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(viewModel.newModelName.isEmpty)
                    }
                }
                
                if viewModel.pullProgress > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloading: \(Int(viewModel.pullProgress * 100))%")
                            .font(.caption)
                        ProgressView(value: viewModel.pullProgress)
                            .progressViewStyle(.linear)
                            .frame(height: 8)
                    }
                    .padding(.top, 4)
                }
                
                if let pullError = viewModel.pullError {
                    Text(pullError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(.controlBackgroundColor) : Color.white)
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
        )
    }
    
    private var serverConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server Configuration")
                .font(.headline)
                .foregroundColor(.primary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection Settings")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if isEditingServerUrl {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Server URL", text: $viewModel.editingServerUrl)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocorrectionDisabled(true)
                        
                        HStack {
                            Spacer()
                            
                            Button("Cancel") {
                                isEditingServerUrl = false
                                viewModel.editingServerUrl = viewModel.serverUrl
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Button("Save") {
                                viewModel.updateServerUrl()
                                isEditingServerUrl = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!viewModel.isValidUrl)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    HStack {
                        Text("Server URL:")
                            .font(.body)
                        
                        Text(viewModel.serverUrl)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                        
                        Spacer()
                        
                        Button(action: {
                            viewModel.editingServerUrl = viewModel.serverUrl
                            isEditingServerUrl = true
                        }) {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 8)
                }
                
                if viewModel.isConnected {
                    HStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                } else if viewModel.isCheckingConnection {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Checking connection...")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                } else if viewModel.connectionError != nil {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(viewModel.connectionError ?? "Connection error")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                
                Text("Ollama needs to be running on your machine for this to work.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(.controlBackgroundColor) : Color.white)
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
        )
    }
    #endif
    
    
    // Keep the original mobile layout
    private var mobileLayout: some View {
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
                    if isEditingServerUrl {
                        VStack(spacing: 10) {
                            TextField("Server URL", text: $viewModel.editingServerUrl)
                                .disableAutocorrection(true)
                            #if os(iOS)
                                .autocapitalization(.none)
                            #endif
                            
                            HStack {
                                Spacer()
                                Button("Cancel") {
                                    isEditingServerUrl = false
                                    viewModel.editingServerUrl = viewModel.serverUrl
                                }
                                Button("Save") {
                                    viewModel.updateServerUrl()
                                    isEditingServerUrl = false
                                }
                                .disabled(!viewModel.isValidUrl)
                            }
                        }
                    } else {
                        HStack {
                            Text("Server URL")
                            Spacer()
                            Text(viewModel.serverUrl)
                                .foregroundColor(.secondary)
                            Button(action: {
                                viewModel.editingServerUrl = viewModel.serverUrl
                                isEditingServerUrl = true
                            }) {
                                Image(systemName: "pencil")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    
                    if viewModel.isConnected {
                        HStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Connected")
                                .foregroundColor(.secondary)
                        }
                    } else if viewModel.isCheckingConnection {
                        HStack {
                            ProgressView()
                            Text("Checking connection...")
                                .foregroundColor(.secondary)
                        }
                    } else if let error = viewModel.connectionError {
                        HStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text(error)
                                .foregroundColor(.red)
                        }
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
            .onAppear {
                ollamaService.refreshModels()
            }
            .refreshable {
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
        
        // Server configuration
        @Published var serverUrl: String
        @Published var editingServerUrl: String = ""
        @Published var isConnected: Bool = false
        @Published var isCheckingConnection: Bool = false
        @Published var connectionError: String? = nil
        
        var isValidUrl: Bool {
            guard let url = URL(string: editingServerUrl) else { return false }
            return url.scheme != nil && url.host != nil
        }
        
        init() {
            // Load server URL from UserDefaults or use default
            self.serverUrl = UserDefaults.standard.string(forKey: "ollamaServerUrl") ?? "http://localhost:11434"
            self.editingServerUrl = self.serverUrl
            
            // Check connection on init
            checkConnection()
        }
        
        func updateServerUrl() {
            guard isValidUrl else { return }
            
            // Save the new URL
            serverUrl = editingServerUrl
            UserDefaults.standard.set(serverUrl, forKey: "ollamaServerUrl")
            
            // Update OllamaService with the new URL
            OllamaService.shared.updateBaseUrl(serverUrl)
            
            // Check connection with new URL
            checkConnection()
        }
        
        func checkConnection() {
            isCheckingConnection = true
            connectionError = nil
            
            Task {
                do {
                    let isReachable = try await OllamaService.shared.checkConnection()
                    await MainActor.run {
                        self.isConnected = isReachable
                        self.isCheckingConnection = false
                        
                        if !isReachable {
                            self.connectionError = "Could not connect to Ollama"
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isConnected = false
                        self.isCheckingConnection = false
                        self.connectionError = error.localizedDescription
                    }
                }
            }
        }
        
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

