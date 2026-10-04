import SwiftUI

public struct ChatGenerationSettingsView: View {
    enum MaximumOutputSelection: Hashable {
        case automatic
        case inactive(savedValue: Int)
        case value(Int)
    }

    @Binding private var maxOutputTokens: Int?
    @Binding private var temperature: Double?
    @Binding private var topP: Double?
    @Binding private var frequencyPenalty: Double?
    @Binding private var presencePenalty: Double?
    @Binding private var topK: Int?
    @Binding private var seed: Int?
    @Binding private var stop: [String]?
    private let capabilities: ChatGenerationCapabilities
    private let reset: () -> Void

    public init(
        maxOutputTokens: Binding<Int?>,
        temperature: Binding<Double?>,
        topP: Binding<Double?>,
        frequencyPenalty: Binding<Double?>,
        presencePenalty: Binding<Double?>,
        topK: Binding<Int?>,
        seed: Binding<Int?>,
        stop: Binding<[String]?>,
        capabilities: ChatGenerationCapabilities,
        reset: @escaping () -> Void
    ) {
        _maxOutputTokens = maxOutputTokens
        _temperature = temperature
        _topP = topP
        _frequencyPenalty = frequencyPenalty
        _presencePenalty = presencePenalty
        _topK = topK
        _seed = seed
        _stop = stop
        self.capabilities = capabilities
        self.reset = reset
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if capabilities.supportsAnyOverride {
                if capabilities.maximumOutputField != nil {
                    maximumOutputControls
                } else {
                    unsupportedField("Maximum output is not supported by this model.")
                }

                if capabilities.supportsTemperature {
                    temperatureControls
                } else {
                    unsupportedField("Temperature is not supported by this model.")
                }

                if capabilities.supportsTopP {
                    topPControls
                }

                if capabilities.supportsFrequencyPenalty {
                    frequencyPenaltyControls
                }

                if capabilities.supportsPresencePenalty {
                    presencePenaltyControls
                }

                if capabilities.supportsTopK {
                    topKControls
                }

                if capabilities.supportsSeed {
                    seedControls
                }

                if capabilities.supportsStop {
                    stopControls
                }
            } else {
                Text(capabilities.unsupportedReason ?? "Advanced generation parameters are unavailable for this model.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Text("Saved values that are unsupported by the selected model are retained and become active again when you switch to a compatible model.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Reset to Automatic", action: reset)
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Maximum Output

    private var maximumOutputControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Maximum Output", isOn: Binding(
                get: { isMaximumOutputActive },
                set: { isEnabled in
                    maxOutputTokens = Self.maximumOutputValue(
                        afterToggle: isEnabled,
                        savedValue: maxOutputTokens,
                        maximumOutputTokenBound: capabilities.maximumOutputTokenBound
                    )
                }
            ))
            .toggleStyle(.switch)

            if isMaximumOutputActive, let maxOutputTokens {
                Picker("Token Limit", selection: Binding(
                    get: { MaximumOutputSelection.value(maxOutputTokens) },
                    set: { selection in
                        guard case .value(let value) = selection else { return }
                        self.maxOutputTokens = value
                    }
                )) {
                    ForEach(tokenChoices, id: \.self) { value in
                        Text(value.formatted()).tag(MaximumOutputSelection.value(value))
                    }
                }
                .pickerStyle(.menu)
            } else if let maxOutputTokens, let bound = capabilities.maximumOutputTokenBound {
                Text("Saved value \(maxOutputTokens.formatted()) exceeds this model's \(bound.formatted()) limit and is retained but inactive. Enable Maximum Output to replace it with a valid limit.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(automaticMaximumOutputDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Available choices and the active bound change with the selected model. The app-wide persistence guard is not a provider guarantee.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let warning = capabilities.maximumOutputWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var tokenChoices: [Int] {
        Self.tokenChoices(
            savedValue: maxOutputTokens,
            maximumOutputTokenBound: capabilities.maximumOutputTokenBound
        )
    }

    private var isMaximumOutputActive: Bool {
        guard case .value = Self.maximumOutputSelection(
            savedValue: maxOutputTokens,
            maximumOutputTokenBound: capabilities.maximumOutputTokenBound
        ) else {
            return false
        }
        return true
    }

    private var automaticMaximumOutputDescription: String {
        Self.automaticMaximumOutputDescription(maximumOutputField: capabilities.maximumOutputField)
    }

    // MARK: - Temperature

    private var temperatureControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Temperature", isOn: Binding(
                get: { temperature != nil },
                set: { isEnabled in
                    temperature = Self.temperatureValue(afterToggle: isEnabled, savedValue: temperature)
                }
            ))
            .toggleStyle(.switch)

            if temperature != nil {
                HStack {
                    Slider(value: Binding(
                        get: { temperature ?? 0.7 },
                        set: { temperature = $0 }
                    ), in: ChatGenerationSettings.temperatureRange, step: 0.05)
                    Text(String(format: "%.2f", temperature ?? 0))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            } else {
                Text("Automatic uses the provider default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Top P

    private var topPControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Top P", isOn: Binding(
                get: { topP != nil },
                set: { isEnabled in
                    topP = isEnabled ? (topP ?? 1.0) : nil
                }
            ))
            .toggleStyle(.switch)

            if topP != nil {
                HStack {
                    Slider(value: Binding(
                        get: { topP ?? 1.0 },
                        set: { topP = $0 }
                    ), in: ChatGenerationSettings.topPRange, step: 0.05)
                    Text(String(format: "%.2f", topP ?? 0))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            } else {
                Text("Automatic uses the provider default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Frequency Penalty

    private var frequencyPenaltyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Frequency Penalty", isOn: Binding(
                get: { frequencyPenalty != nil },
                set: { isEnabled in
                    frequencyPenalty = isEnabled ? (frequencyPenalty ?? 0) : nil
                }
            ))
            .toggleStyle(.switch)

            if frequencyPenalty != nil {
                HStack {
                    Slider(value: Binding(
                        get: { frequencyPenalty ?? 0 },
                        set: { frequencyPenalty = $0 }
                    ), in: ChatGenerationSettings.penaltyRange, step: 0.05)
                    Text(String(format: "%+.2f", frequencyPenalty ?? 0))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            } else {
                Text("Automatic uses the provider default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Presence Penalty

    private var presencePenaltyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Presence Penalty", isOn: Binding(
                get: { presencePenalty != nil },
                set: { isEnabled in
                    presencePenalty = isEnabled ? (presencePenalty ?? 0) : nil
                }
            ))
            .toggleStyle(.switch)

            if presencePenalty != nil {
                HStack {
                    Slider(value: Binding(
                        get: { presencePenalty ?? 0 },
                        set: { presencePenalty = $0 }
                    ), in: ChatGenerationSettings.penaltyRange, step: 0.05)
                    Text(String(format: "%+.2f", presencePenalty ?? 0))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            } else {
                Text("Automatic uses the provider default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Top K

    private var topKControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Top K", isOn: Binding(
                get: { topK != nil },
                set: { isEnabled in
                    topK = isEnabled ? (topK ?? 40) : nil
                }
            ))
            .toggleStyle(.switch)

            if topK != nil {
                HStack {
                    Stepper("Top K: \(topK ?? 40)", value: Binding(
                        get: { topK ?? 40 },
                        set: { topK = $0 }
                    ), in: 1...200)
                }
            } else {
                Text("Automatic uses the provider default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Seed

    private var seedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Seed", isOn: Binding(
                get: { seed != nil },
                set: { isEnabled in
                    seed = isEnabled ? (seed ?? Int.random(in: 0...Int.max)) : nil
                }
            ))
            .toggleStyle(.switch)

            if seed != nil {
                HStack {
                    TextField("Seed", value: Binding(
                        get: { seed ?? 0 },
                        set: { seed = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    Button("Random") {
                        seed = Int.random(in: 0...Int.max)
                    }
                }
            } else {
                Text("Automatic uses the provider default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Stop Sequences

    private var stopControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Stop Sequences", isOn: Binding(
                get: { stop != nil },
                set: { isEnabled in
                    stop = isEnabled ? (stop ?? []) : nil
                }
            ))
            .toggleStyle(.switch)

            if let stopSequences = stop {
                ForEach(stopSequences.indices, id: \.self) { index in
                    HStack {
                        TextField("Stop sequence", text: Binding(
                            get: { stopSequences.indices.contains(index) ? stopSequences[index] : "" },
                            set: { newValue in
                                guard stopSequences.indices.contains(index) else { return }
                                if newValue.isEmpty {
                                    stop?.remove(at: index)
                                    if stop?.isEmpty == true { stop = nil }
                                } else {
                                    stop?[index] = newValue
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            stop?.remove(at: index)
                            if stop?.isEmpty == true { stop = nil }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    stop?.append("")
                } label: {
                    Label("Add Stop Sequence", systemImage: "plus.circle")
                }
            } else {
                Text("Stop sequences halt generation when encountered. Automatic uses the provider default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Static helpers

    static func automaticMaximumOutputDescription(
        maximumOutputField: ChatGenerationCapabilities.MaximumOutputField?
    ) -> String {
        if maximumOutputField == .anthropicMaxTokens {
            return "The app sends the required default of 4,096 tokens."
        }
        return "Automatic uses the provider default."
    }

    static func maximumOutputSelection(
        savedValue: Int?,
        maximumOutputTokenBound: Int?
    ) -> MaximumOutputSelection {
        guard let savedValue else { return .automatic }
        guard let bound = maximumOutputTokenBound,
              savedValue <= bound else {
            return .inactive(savedValue: savedValue)
        }
        return .value(savedValue)
    }

    static func maximumOutputValue(
        afterToggle isEnabled: Bool,
        savedValue: Int?,
        maximumOutputTokenBound: Int?
    ) -> Int? {
        guard isEnabled, let bound = maximumOutputTokenBound else { return nil }
        if let savedValue, savedValue <= bound {
            return savedValue
        }
        return defaultMaximumOutputTokens(maximumOutputTokenBound: bound)
    }

    static func maximumOutputValueWhenEnabled(
        savedValue: Int?,
        maximumOutputTokenBound: Int?
    ) -> Int? {
        maximumOutputValue(
            afterToggle: true,
            savedValue: savedValue,
            maximumOutputTokenBound: maximumOutputTokenBound
        )
    }

    static func tokenChoices(savedValue: Int?, maximumOutputTokenBound: Int?) -> [Int] {
        guard let bound = maximumOutputTokenBound else { return [] }
        var choices = ChatGenerationSettings.tokenPresets.filter { $0 <= bound }
        if !choices.contains(bound) {
            choices.append(bound)
        }
        if let savedValue,
           savedValue <= bound,
           !choices.contains(savedValue) {
            choices.append(savedValue)
        }
        if choices.isEmpty {
            choices.append(bound)
        }
        return choices.sorted()
    }

    static func defaultMaximumOutputTokens(maximumOutputTokenBound: Int?) -> Int {
        guard let bound = maximumOutputTokenBound else { return 4_096 }
        return min(4_096, bound)
    }

    static func temperatureValue(afterToggle isEnabled: Bool, savedValue: Double?) -> Double? {
        isEnabled ? (savedValue ?? 0.7) : nil
    }

    private func unsupportedField(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
    }
}