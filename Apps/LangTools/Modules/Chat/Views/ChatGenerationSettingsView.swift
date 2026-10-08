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
        VStack(alignment: .leading, spacing: 16) {
            if capabilities.supportsAnyOverride {
                if capabilities.maximumOutputField != nil || capabilities.supportsStop {
                    outputSection
                }

                if capabilities.supportsTemperature || capabilities.supportsTopP || capabilities.supportsTopK {
                    samplingSection
                }

                if capabilities.supportsFrequencyPenalty || capabilities.supportsPresencePenalty {
                    penaltiesSection
                }

                if capabilities.supportsSeed {
                    seedSection
                }
            } else {
                unsupportedMessage
            }

            savedValuesFootnote

            HStack {
                Spacer()
                Button("Reset to Automatic", action: reset)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Sections

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Output")
            Divider()

            if capabilities.maximumOutputField != nil {
                maximumOutputRow
            }

            if capabilities.supportsStop {
                stopRow
            }
        }
    }

    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Sampling")
            Divider()

            if capabilities.supportsTemperature {
                checkboxSliderRow(
                    label: "Temperature",
                    isOn: Binding(get: { temperature != nil }, set: { temperature = $0 ? (temperature ?? 0.7) : nil }),
                    value: Binding(get: { temperature ?? 0.7 }, set: { temperature = $0 }),
                    range: ChatGenerationSettings.temperatureRange,
                    step: 0.05,
                    format: "%.2f"
                )
            }

            if capabilities.supportsTopP {
                checkboxSliderRow(
                    label: "Top P",
                    isOn: Binding(get: { topP != nil }, set: { topP = $0 ? (topP ?? 1.0) : nil }),
                    value: Binding(get: { topP ?? 1.0 }, set: { topP = $0 }),
                    range: ChatGenerationSettings.topPRange,
                    step: 0.05,
                    format: "%.2f"
                )
            }

            if capabilities.supportsTopK {
                checkboxStepperRow(
                    label: "Top K",
                    isOn: Binding(get: { topK != nil }, set: { topK = $0 ? (topK ?? 40) : nil }),
                    value: Binding(get: { topK ?? 40 }, set: { topK = $0 }),
                    range: 1...200
                )
            }
        }
    }

    private var penaltiesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Penalties")
            Divider()

            if capabilities.supportsFrequencyPenalty {
                checkboxSliderRow(
                    label: "Frequency Penalty",
                    isOn: Binding(get: { frequencyPenalty != nil }, set: { frequencyPenalty = $0 ? (frequencyPenalty ?? 0) : nil }),
                    value: Binding(get: { frequencyPenalty ?? 0 }, set: { frequencyPenalty = $0 }),
                    range: ChatGenerationSettings.penaltyRange,
                    step: 0.05,
                    format: "%+.2f"
                )
            }

            if capabilities.supportsPresencePenalty {
                checkboxSliderRow(
                    label: "Presence Penalty",
                    isOn: Binding(get: { presencePenalty != nil }, set: { presencePenalty = $0 ? (presencePenalty ?? 0) : nil }),
                    value: Binding(get: { presencePenalty ?? 0 }, set: { presencePenalty = $0 }),
                    range: ChatGenerationSettings.penaltyRange,
                    step: 0.05,
                    format: "%+.2f"
                )
            }
        }
    }

    private var seedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Reproducibility")
            Divider()

            checkboxSeedRow(
                isOn: Binding(get: { seed != nil }, set: { seed = $0 ? (seed ?? Int.random(in: 0...Int.max)) : nil }),
                value: Binding(get: { seed ?? 0 }, set: { seed = $0 })
            )
        }
    }

    // MARK: - Rows

    private var maximumOutputRow: some View {
        HStack(spacing: 8) {
            if capabilities.maximumOutputField != nil {
                Toggle(isOn: maximumOutputToggle) {
                    Text("Max Tokens").frame(width: labelWidth - 20, alignment: .leading)
                }
                .checkboxToggleStyle()
            } else {
                Text("Max Tokens")
                    .frame(width: labelWidth, alignment: .leading)
            }

            if isMaximumOutputActive, let maxOutputTokens {
                Picker(selection: Binding(
                    get: { MaximumOutputSelection.value(maxOutputTokens) },
                    set: { if case .value(let v) = $0 { self.maxOutputTokens = v } }
                )) {
                    ForEach(tokenChoices, id: \.self) { value in
                        Text(value.formatted()).tag(MaximumOutputSelection.value(value))
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 100)

                if let warning = capabilities.maximumOutputWarning {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help(warning)
                }
            } else if let maxOutputTokens, let bound = capabilities.maximumOutputTokenBound {
                Text("\(maxOutputTokens) exceeds \(bound) limit — inactive")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(automaticDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    /// Toggling on enables an override (falling back to a safe default when the
    /// model has no known token bound); toggling off clears it.
    private var maximumOutputToggle: Binding<Bool> {
        Binding(
            get: { maxOutputTokens != nil },
            set: { enabled in
                maxOutputTokens = enabled
                    ? Self.maximumOutputValueWhenEnabled(
                        savedValue: maxOutputTokens,
                        maximumOutputTokenBound: capabilities.maximumOutputTokenBound
                    ) ?? Self.defaultMaximumOutputTokens(maximumOutputTokenBound: capabilities.maximumOutputTokenBound)
                    : nil
            }
        )
    }

    private var stopRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { stop != nil },
                    set: { stop = $0 ? (stop ?? []) : nil }
                )) {
                    Text("Stop Sequences").frame(width: labelWidth - 20, alignment: .leading)
                }
                .checkboxToggleStyle()

                if stop == nil {
                    Text("Automatic")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if let stopSequences = stop {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(stopSequences.indices, id: \.self) { index in
                        HStack(spacing: 4) {
                            TextField("sequence", text: Binding(
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
                            .frame(width: 160)

                            Button {
                                stop?.remove(at: index)
                                if stop?.isEmpty == true { stop = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        stop?.append("")
                    } label: {
                        Label("Add", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, labelWidth + 8)
            }
        }
    }

    // MARK: - Reusable row builders

    private func checkboxSliderRow(
        label: String,
        isOn: Binding<Bool>,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: isOn) {
                Text(label).frame(width: labelWidth - 20, alignment: .leading)
            }
            .checkboxToggleStyle()

            if isOn.wrappedValue {
                Slider(value: value, in: range, step: step)
                    .frame(maxWidth: 180)

                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
                    .font(.caption)
            } else {
                Text("Automatic")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private func checkboxStepperRow(
        label: String,
        isOn: Binding<Bool>,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: isOn) {
                Text(label).frame(width: labelWidth - 20, alignment: .leading)
            }
            .checkboxToggleStyle()

            if isOn.wrappedValue {
                Stepper(value: value, in: range) {
                    Text("\(value.wrappedValue)")
                        .monospacedDigit()
                        .frame(minWidth: 30, alignment: .trailing)
                }
                .frame(maxWidth: 200)
            } else {
                Text("Automatic")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private func checkboxSeedRow(
        isOn: Binding<Bool>,
        value: Binding<Int>
    ) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: isOn) {
                Text("Seed").frame(width: labelWidth - 20, alignment: .leading)
            }
            .checkboxToggleStyle()

            if isOn.wrappedValue {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .monospacedDigit()

                Button("Random") {
                    seed = Int.random(in: 0...Int.max)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("Automatic")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
    }

    private var unsupportedMessage: some View {
        Text(capabilities.unsupportedReason ?? "Advanced generation parameters are unavailable for this model.")
            .font(.callout)
            .foregroundColor(.secondary)
    }

    private var savedValuesFootnote: some View {
        Text("Saved values for unsupported models are retained and reactivate when switching back.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private var labelWidth: CGFloat { 150 }

    private var automaticDescription: String {
        Self.automaticMaximumOutputDescription(maximumOutputField: capabilities.maximumOutputField)
    }

    private var tokenChoices: [Int] {
        Self.tokenChoices(savedValue: maxOutputTokens, maximumOutputTokenBound: capabilities.maximumOutputTokenBound)
    }

    private var isMaximumOutputActive: Bool {
        guard capabilities.maximumOutputField != nil else { return false }
        guard case .value = Self.maximumOutputSelection(
            savedValue: maxOutputTokens, maximumOutputTokenBound: capabilities.maximumOutputTokenBound
        ) else { return false }
        return true
    }

    // MARK: - Static helpers

    static func automaticMaximumOutputDescription(
        maximumOutputField: ChatGenerationCapabilities.MaximumOutputField?
    ) -> String {
        if maximumOutputField == .anthropicMaxTokens {
            return "The app sends the required default of 4,096 tokens."
        }
        return "Automatic"
    }

    static func maximumOutputSelection(
        savedValue: Int?,
        maximumOutputTokenBound: Int?
    ) -> MaximumOutputSelection {
        guard let savedValue else { return .automatic }
        // A missing bound is unconstrained, not inactive: the saved value still
        // applies. Only a known bound can rule a value out.
        if let bound = maximumOutputTokenBound, savedValue > bound {
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
        if let savedValue, savedValue <= bound { return savedValue }
        return defaultMaximumOutputTokens(maximumOutputTokenBound: bound)
    }

    static func maximumOutputValueWhenEnabled(
        savedValue: Int?,
        maximumOutputTokenBound: Int?
    ) -> Int? {
        maximumOutputValue(afterToggle: true, savedValue: savedValue, maximumOutputTokenBound: maximumOutputTokenBound)
    }

    static func tokenChoices(savedValue: Int?, maximumOutputTokenBound: Int?) -> [Int] {
        var choices = ChatGenerationSettings.tokenPresets
        if let bound = maximumOutputTokenBound {
            choices = choices.filter { $0 <= bound }
            if !choices.contains(bound) { choices.append(bound) }
        }
        if let savedValue,
           maximumOutputTokenBound.map({ savedValue <= $0 }) ?? true,
           !choices.contains(savedValue) {
            choices.append(savedValue)
        }
        if choices.isEmpty { choices.append(4_096) }
        return choices.sorted()
    }

    static func defaultMaximumOutputTokens(maximumOutputTokenBound: Int?) -> Int {
        guard let bound = maximumOutputTokenBound else { return 4_096 }
        return min(4_096, bound)
    }

    static func temperatureValue(afterToggle isEnabled: Bool, savedValue: Double?) -> Double? {
        isEnabled ? (savedValue ?? 0.7) : nil
    }
}