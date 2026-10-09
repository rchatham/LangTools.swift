//
//  OllamaSettingsView.swift
//  App
//
//  Created by Reid Chatham on 2/26/25.
//


import SwiftUI
import Ollama

@MainActor
struct OllamaSettingsView: View {
    @StateObject private var viewModel: ViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ollamaService: OllamaService
    @Environment(\.colorScheme) private var colorScheme
    @State private var isEditingServerUrl = false

    init() {
        self.init(ollamaService: .shared)
    }

    init(
        ollamaService: OllamaService,
        endpointConfiguration: OllamaEndpointConfiguration? = nil
    ) {
        _ollamaService = ObservedObject(wrappedValue: ollamaService)
        _viewModel = StateObject(wrappedValue: ViewModel(
            ollamaService: ollamaService,
            endpointConfiguration: endpointConfiguration ?? ollamaService.endpointConfiguration
        ))
    }
    
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
                    helperTransportSection

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
        .onAppear { viewModel.activate() }
        .onChange(of: ollamaService.transportRevision) { _, _ in viewModel.transportDidChange() }
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
                                if viewModel.updateServerUrl() {
                                    isEditingServerUrl = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    if let validationError = viewModel.endpointValidationError {
                        Text(validationError)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.vertical, 8)
                    }
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
                
                Text("On iPhone, localhost refers to the phone. Use a reachable LAN address for the Mac running Ollama, such as http://192.168.1.10:11434.")
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
    
    
    private var helperTransportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let helperID = viewModel.helperID {
                Label("Via LangToolsHelper", systemImage: "lock.shield")
                    .font(.headline)
                Text(viewModel.helperName ?? "Paired Mac").font(.title3)
                Text(helperID).font(.caption2).foregroundStyle(.secondary)
                if viewModel.isCheckingConnection {
                    ProgressView("Verifying connection…")
                } else if let error = viewModel.connectionError ?? ollamaService.error?.localizedDescription {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if viewModel.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
                Button("Retry Helper") { viewModel.checkConnection(); ollamaService.refreshModels() }
                Button("Disconnect Helper", role: .destructive) { viewModel.disconnectHelper() }
                    .accessibilityIdentifier("mobile-helper-disconnect")
                Button("Use Direct Ollama Instead") { viewModel.useDirect() }
                    .accessibilityIdentifier("mobile-helper-use-direct")
            } else {
                Label("Direct Ollama", systemImage: "network").font(.headline)
            }
            Text("To connect securely via your Mac, choose Connect iPhone in LangToolsHelper, then scan its QR using the iPhone Camera. Direct Ollama remains an explicit alternative below; saving a direct URL switches transport.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    // Keep the original mobile layout
    private var mobileLayout: some View {
        NavigationStack {
            List {
                Section(header: Text("Ollama Transport")) { helperTransportSection }
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
                                    if viewModel.updateServerUrl() {
                                        isEditingServerUrl = false
                                    }
                                }
                            }
                        }
                        if let validationError = viewModel.endpointValidationError {
                            Text(validationError)
                                .font(.caption)
                                .foregroundColor(.red)
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
                    
                    Text("On iPhone, localhost is the phone. Enter the reachable LAN address of the Mac running Ollama.")
                        .font(.caption)
                        .foregroundColor(.secondary)

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
            .onAppear { viewModel.activate() }
            .onChange(of: ollamaService.transportRevision) { _, _ in viewModel.transportDidChange() }
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
        @Published var helperID: String?
        @Published var helperName: String?
        @Published var serverUrl: String
        @Published var editingServerUrl: String = ""
        @Published var isConnected: Bool = false
        @Published var isCheckingConnection: Bool = false
        @Published var connectionError: String? = nil
        @Published var endpointValidationError: String? = nil

        private let ollamaService: OllamaService
        private let endpointConfiguration: OllamaEndpointConfiguration
        private var connectionGeneration: UInt64 = 0
        private var loadGeneration: UInt64 = 0
        private var pullGeneration: UInt64 = 0

        var isValidUrl: Bool {
            (try? OllamaEndpointConfiguration.validate(editingServerUrl)) != nil
        }

        convenience init() {
            self.init(ollamaService: .shared)
        }

        init(
            ollamaService: OllamaService,
            endpointConfiguration: OllamaEndpointConfiguration? = nil
        ) {
            self.ollamaService = ollamaService
            let resolvedConfiguration = endpointConfiguration ?? ollamaService.endpointConfiguration
            self.endpointConfiguration = resolvedConfiguration
            let snapshot = resolvedConfiguration.snapshot()
            helperID = snapshot.helperID
            helperName = snapshot.helperName
            serverUrl = resolvedConfiguration.directBaseURL?.absoluteString ?? ""
            editingServerUrl = serverUrl
            endpointValidationError = resolvedConfiguration.directValidationError?.localizedDescription
        }

        func activate() {
            transportDidChange()
            ollamaService.refreshModels()
        }

        func transportDidChange() {
            let snapshot = endpointConfiguration.snapshot()
            helperID = snapshot.helperID
            helperName = snapshot.helperName
            serverUrl = endpointConfiguration.directBaseURL?.absoluteString ?? ""
            editingServerUrl = serverUrl
            endpointValidationError = endpointConfiguration.directValidationError?.localizedDescription
            loadGeneration &+= 1
            pullGeneration &+= 1
            loadingModelName = nil
            isPulling = false
            pullProgress = 0
            pullError = nil
            checkConnection(for: snapshot)
        }

        func disconnectHelper() {
            do {
                try endpointConfiguration.disconnectHelper()
                ollamaService.transportDidChange()
                transportDidChange()
            } catch { connectionError = MobileHelperError.persistence(error.localizedDescription).localizedDescription }
        }

        func useDirect() {
            endpointConfiguration.useDirect()
            ollamaService.transportDidChange()
            transportDidChange()
        }

        @discardableResult
        func updateServerUrl() -> Bool {
            do {
                let previousSnapshot = endpointConfiguration.snapshot()
                let snapshot = try ollamaService.updateEndpoint(editingServerUrl)
                guard snapshot != previousSnapshot else { return true }
                loadGeneration &+= 1
                pullGeneration &+= 1
                loadingModelName = nil
                isPulling = false
                pullProgress = 0
                pullError = nil
                helperID = snapshot.helperID
                helperName = snapshot.helperName
                serverUrl = endpointConfiguration.directBaseURL?.absoluteString ?? ""
                editingServerUrl = serverUrl
                endpointValidationError = nil
                checkConnection(for: snapshot)
                return true
            } catch {
                endpointValidationError = error.localizedDescription
                return false
            }
        }

        func checkConnection(
            for snapshot: OllamaEndpointConfiguration.Snapshot? = nil
        ) {
            let capturedSnapshot = snapshot ?? endpointConfiguration.snapshot()
            connectionGeneration &+= 1
            let generation = connectionGeneration
            isCheckingConnection = true
            isConnected = false
            connectionError = nil

            Task {
                do {
                    try await ollamaService.checkConnection(for: capturedSnapshot)
                    try Task.checkCancellation()
                    guard generation == connectionGeneration,
                          endpointConfiguration.isCurrent(capturedSnapshot) else { return }
                    isConnected = true
                    isCheckingConnection = false
                } catch {
                    guard generation == connectionGeneration,
                          endpointConfiguration.isCurrent(capturedSnapshot) else { return }
                    guard !(error is CancellationError), !Task.isCancelled else { return }
                    isConnected = false
                    isCheckingConnection = false
                    connectionError = "Could not connect to the selected Ollama source. \(error.localizedDescription)"
                }
            }
        }
        
        func toggleModel(_ model: Ollama.Model) {
            if ollamaService.runningModels.contains(where: { $0.model == model.rawValue }) {
                // Model is already running, no need to do anything
                return
            }
            
            loadingModelName = model.rawValue
            loadGeneration &+= 1
            let generation = loadGeneration
            let snapshot = endpointConfiguration.snapshot()

            Task {
                do {
                    try await ollamaService.loadModel(model, for: snapshot)
                    guard generation == loadGeneration,
                          endpointConfiguration.isCurrent(snapshot) else { return }
                    loadingModelName = nil
                } catch {
                    guard generation == loadGeneration,
                          endpointConfiguration.isCurrent(snapshot) else { return }
                    loadingModelName = nil
                    connectionError = snapshot.actionableError(error).localizedDescription
                }
            }
        }
        
        func pullModel() {
            guard !newModelName.isEmpty, !isPulling else { return }
            isPulling = true
            pullError = nil
            pullProgress = 0
            pullGeneration &+= 1
            let generation = pullGeneration
            let snapshot = endpointConfiguration.snapshot()

            Task {
                do {
                    try await ollamaService.pullModel(newModelName, for: snapshot) { [weak self] progress in
                        guard let self,
                              generation == self.pullGeneration,
                              self.endpointConfiguration.isCurrent(snapshot) else { return }
                        self.pullProgress = progress
                    }
                    guard generation == pullGeneration,
                          endpointConfiguration.isCurrent(snapshot) else { return }
                    isPulling = false
                    newModelName = ""
                    pullProgress = 0
                } catch {
                    guard generation == pullGeneration,
                          endpointConfiguration.isCurrent(snapshot) else { return }
                    isPulling = false
                    pullError = snapshot.actionableError(error).localizedDescription
                }
            }
        }
    }
}

#Preview {
    OllamaSettingsView()
}

