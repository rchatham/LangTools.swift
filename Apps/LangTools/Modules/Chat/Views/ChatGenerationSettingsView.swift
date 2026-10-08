import SwiftUI

/// Blank rows are editing drafts, not persisted stop sequences. Row identities stay
/// stable across edits so a delayed TextField write cannot target a different row.
struct StopSequenceEditing {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    private(set) var isEnabled: Bool
    private(set) var rows: [Row]
    private var lastBindingValue: [String]?

    init(value: [String]?) {
        isEnabled = value != nil
        rows = (value ?? []).filter { !$0.isEmpty }.map { Row(text: $0) }
        lastBindingValue = value
    }

    var value: [String]? {
        isEnabled ? rows.map(\.text).filter { !$0.isEmpty } : nil
    }

    /// An echo of our own publication must not discard drafts or replace row IDs.
    mutating func synchronize(with value: [String]?, discardingDrafts: Bool = false) {
        guard discardingDrafts || value != lastBindingValue else { return }
        self = Self(value: value)
    }

    mutating func valueForPublishing() -> [String]? {
        lastBindingValue = value
        return value
    }

    mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { rows.removeAll() }
    }

    mutating func add() {
        guard isEnabled else { return }
        rows.append(Row(text: ""))
    }

    @discardableResult
    mutating func updateText(_ text: String, for id: Row.ID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        rows[index].text = text
        return true
    }

    @discardableResult
    mutating func remove(id: Row.ID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        rows.remove(at: index)
        if rows.isEmpty { isEnabled = false }
        return true
    }
}

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
    @State private var stopEditing: StopSequenceEditing
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
        _stopEditing = State(initialValue: StopSequenceEditing(value: stop.wrappedValue))
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
                Button("Reset to Automatic") {
                    stopEditing.synchronize(with: nil, discardingDrafts: true)
                    reset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .onAppear {
            stopEditing.synchronize(with: stop, discardingDrafts: true)
        }
        .onChange(of: stop) { value in
            stopEditing.synchronize(with: value)
        }
        .onChange(of: capabilities) { _ in
            // Capabilities are the available model-change signal, not model identity.
            stopEditing.synchronize(with: stop, discardingDrafts: true)
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
            Text("Max Tokens")
                .frame(width: labelWidth, alignment: .leading)

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

    private var stopRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { stopEditing.isEnabled },
                    set: { enabled in
                        editStopSequences {
                            $0.setEnabled(enabled)
                            return true
                        }
                    }
                )) {
                    Text("Stop Sequences").frame(width: labelWidth - 20, alignment: .leading)
                }
                .accessibilityIdentifier("generation.stop.toggle")
#if os(macOS)
                .toggleStyle(.checkbox)
#else
                .toggleStyle(.switch)
#endif

                if !stopEditing.isEnabled {
                    Text("Automatic")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if stopEditing.isEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(stopEditing.rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 4) {
                            TextField("sequence", text: Binding(
                                get: { stopEditing.rows.first(where: { $0.id == row.id })?.text ?? "" },
                                set: { newValue in
                                    editStopSequences { $0.updateText(newValue, for: row.id) }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("generation.stop.sequence.\(index)")
                            .frame(width: 160)

                            Button {
                                editStopSequences { $0.remove(id: row.id) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .accessibilityIdentifier("generation.stop.remove.\(index)")
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        editStopSequences {
                            $0.add()
                            return true
                        }
                    } label: {
                        Label("Add", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .accessibilityIdentifier("generation.stop.add")
                    .buttonStyle(.plain)
                }
                .padding(.leading, labelWidth + 8)
            }
        }
    }

    private func editStopSequences(_ edit: (inout StopSequenceEditing) -> Bool) {
        // Reconcile before handling events too: a stale field may write before the
        // binding's onChange callback has delivered an external reset/update.
        stopEditing.synchronize(with: stop)
        guard edit(&stopEditing) else { return }
        stop = stopEditing.valueForPublishing()
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
            .accessibilityIdentifier("generation.\(label.lowercased().replacingOccurrences(of: " ", with: ".")).toggle")
#if os(macOS)
            .toggleStyle(.checkbox)
#else
            .toggleStyle(.switch)
#endif

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
            .accessibilityIdentifier("generation.\(label.lowercased().replacingOccurrences(of: " ", with: ".")).toggle")
#if os(macOS)
            .toggleStyle(.checkbox)
#else
            .toggleStyle(.switch)
#endif

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
            .accessibilityIdentifier("generation.seed.toggle")
#if os(macOS)
            .toggleStyle(.checkbox)
#else
            .toggleStyle(.switch)
#endif

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
        guard let bound = maximumOutputTokenBound, savedValue <= bound else {
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
        guard let bound = maximumOutputTokenBound else { return [] }
        var choices = ChatGenerationSettings.tokenPresets.filter { $0 <= bound }
        if !choices.contains(bound) { choices.append(bound) }
        if let savedValue, savedValue <= bound, !choices.contains(savedValue) {
            choices.append(savedValue)
        }
        if choices.isEmpty { choices.append(bound) }
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