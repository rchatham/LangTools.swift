import SwiftUI

public struct ChatGenerationSettingsView: View {
    enum MaximumOutputSelection: Hashable {
        case automatic
        case inactive(savedValue: Int)
        case value(Int)
    }

    @Binding private var maxOutputTokens: Int?
    @Binding private var temperature: Double?
    private let capabilities: ChatGenerationCapabilities
    private let reset: () -> Void

    public init(
        maxOutputTokens: Binding<Int?>,
        temperature: Binding<Double?>,
        capabilities: ChatGenerationCapabilities,
        reset: @escaping () -> Void
    ) {
        _maxOutputTokens = maxOutputTokens
        _temperature = temperature
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
                Text("Saved value \(maxOutputTokens.formatted()) exceeds this model’s \(bound.formatted()) limit and is retained but inactive. Enable Maximum Output to replace it with a valid limit.")
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

    static func temperatureValue(afterToggle isEnabled: Bool, savedValue: Double?) -> Double? {
        isEnabled ? (savedValue ?? 0.7) : nil
    }

    private func unsupportedField(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
