import Anthropic
import XCTest
@testable import Chat

@MainActor
final class ChatSettingsViewModelTests: XCTestCase {
    func testLoadSaveAndResetUseInjectedStore() throws {
        let initial = try ChatGenerationSettings(maxOutputTokens: 2_048, temperature: 0.4)
        let store = FakeGenerationSettingsStore(settings: initial)
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {}, generationSettingsStore: store)

        viewModel.loadSettings()
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(viewModel.generationSettings, initial)

        viewModel.updateMaximumOutputTokens(8_192)
        viewModel.saveSettings()
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.settings, try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0.4))

        viewModel.resetGenerationSettings()
        XCTAssertEqual(store.resetCount, 1)
        XCTAssertEqual(viewModel.generationSettings, .automatic)
        XCTAssertEqual(store.settings, .automatic)
    }

    func testExplicitTemperatureZeroSurvivesSaveAndReload() {
        let store = FakeGenerationSettingsStore()
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {}, generationSettingsStore: store)

        viewModel.updateTemperature(0)
        viewModel.saveSettings()
        viewModel.loadSettings()

        XCTAssertEqual(viewModel.generationSettings.temperature, 0)
    }

    func testOverboundSettingIsPreservedAcrossModelChanges() throws {
        let settings = try ChatGenerationSettings(maxOutputTokens: 8_192, temperature: 0.25)
        let store = FakeGenerationSettingsStore(settings: settings)
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {}, generationSettingsStore: store)
        viewModel.generationSettings = settings

        viewModel.model = .openAI(.gpt4)
        XCTAssertEqual(viewModel.model.generationCapabilities.maximumOutputTokenBound, 4_096)
        XCTAssertEqual(viewModel.generationSettings, settings)

        viewModel.model = .openAI(.gpt4o_mini)
        XCTAssertEqual(viewModel.model.generationCapabilities.maximumOutputTokenBound, 16_384)
        XCTAssertEqual(viewModel.generationSettings, settings)
    }

    func testMaximumOutputPickerRepresentsOverboundSavedValueAsInactive() {
        XCTAssertEqual(
            ChatGenerationSettingsView.maximumOutputSelection(
                savedValue: 8_192,
                maximumOutputTokenBound: 4_096
            ),
            .inactive(savedValue: 8_192)
        )
        XCTAssertEqual(
            ChatGenerationSettingsView.tokenChoices(
                savedValue: 8_192,
                maximumOutputTokenBound: 4_096
            ),
            [1_024, 2_048, 4_096]
        )
    }

    func testMaximumOutputPickerSelectionReactivatesWithExplicitValidValue() {
        XCTAssertEqual(
            ChatGenerationSettingsView.maximumOutputSelection(
                savedValue: 4_096,
                maximumOutputTokenBound: 4_096
            ),
            .value(4_096)
        )
    }

    func testEnablingOverboundMaximumOutputChoosesValidValue() {
        XCTAssertEqual(
            ChatGenerationSettingsView.maximumOutputValueWhenEnabled(
                savedValue: 8_192,
                maximumOutputTokenBound: 4_096
            ),
            4_096
        )
        XCTAssertEqual(
            ChatGenerationSettingsView.maximumOutputValueWhenEnabled(
                savedValue: 8_192,
                maximumOutputTokenBound: 512
            ),
            512
        )
    }

    func testAnthropicAutomaticMaximumOutputExplainsAppRequiredDefault() {
        XCTAssertEqual(
            ChatGenerationSettingsView.automaticMaximumOutputDescription(
                maximumOutputField: .anthropicMaxTokens
            ),
            "The app sends the required default of 4,096 tokens."
        )
    }

    func testMaximumOutputPickerIncludesValidCustomValueAndHonorsSmallBound() {
        XCTAssertEqual(
            ChatGenerationSettingsView.tokenChoices(
                savedValue: 3_000,
                maximumOutputTokenBound: 4_096
            ),
            [1_024, 2_048, 3_000, 4_096]
        )
        XCTAssertEqual(
            ChatGenerationSettingsView.tokenChoices(
                savedValue: nil,
                maximumOutputTokenBound: 512
            ),
            [512]
        )
        XCTAssertEqual(
            ChatGenerationSettingsView.defaultMaximumOutputTokens(maximumOutputTokenBound: 512),
            512
        )
    }

    func testTokenPersistenceGuardAllowsDocumentedHighValues() throws {
        XCTAssertEqual(ChatGenerationSettings.tokenRange, 1...1_000_000)
        XCTAssertEqual(
            Array(ChatGenerationSettings.tokenPresets.suffix(4)),
            [65_536, 100_000, 128_000, 272_000]
        )
        XCTAssertEqual(
            try ChatGenerationSettings(maxOutputTokens: 272_000).maxOutputTokens,
            272_000
        )
        XCTAssertEqual(
            try ChatGenerationSettings(maxOutputTokens: 1_000_000).maxOutputTokens,
            1_000_000
        )
        XCTAssertThrowsError(try ChatGenerationSettings(maxOutputTokens: 1_000_001))
    }

    func testHighBoundPickerIncludesDocumentedPresetsOnlyUpToModelBound() {
        XCTAssertEqual(
            Array(ChatGenerationSettingsView.tokenChoices(
                savedValue: nil,
                maximumOutputTokenBound: 128_000
            ).suffix(3)),
            [65_536, 100_000, 128_000]
        )
        XCTAssertFalse(
            ChatGenerationSettingsView.tokenChoices(
                savedValue: nil,
                maximumOutputTokenBound: 128_000
            ).contains(272_000)
        )
        XCTAssertTrue(
            ChatGenerationSettingsView.tokenChoices(
                savedValue: nil,
                maximumOutputTokenBound: 272_000
            ).contains(272_000)
        )
        XCTAssertTrue(
            ChatGenerationSettingsView.tokenChoices(
                savedValue: nil,
                maximumOutputTokenBound: 1_000_000
            ).contains(1_000_000)
        )
    }

    func testToggleMutatorsEnableDefaultsPreserveValuesAndDisableOverrides() {
        XCTAssertEqual(
            ChatGenerationSettingsView.maximumOutputValue(
                afterToggle: true,
                savedValue: nil,
                maximumOutputTokenBound: 128_000
            ),
            4_096
        )
        XCTAssertNil(
            ChatGenerationSettingsView.maximumOutputValue(
                afterToggle: false,
                savedValue: 100_000,
                maximumOutputTokenBound: 128_000
            )
        )
        XCTAssertEqual(
            ChatGenerationSettingsView.temperatureValue(afterToggle: true, savedValue: nil),
            0.7
        )
        XCTAssertEqual(
            ChatGenerationSettingsView.temperatureValue(afterToggle: true, savedValue: 0),
            0
        )
        XCTAssertNil(ChatGenerationSettingsView.temperatureValue(afterToggle: false, savedValue: 0.4))
    }

    func testUnsupportedModelDoesNotEraseDraftOverrides() throws {
        let anthropic = try XCTUnwrap(Anthropic.Model.allCases.first)
        let settings = try ChatGenerationSettings(maxOutputTokens: 4_096, temperature: 0.25)
        let store = FakeGenerationSettingsStore(settings: settings)
        let viewModel = ChatSettingsView.ViewModel(clearMessages: {}, generationSettingsStore: store)
        viewModel.generationSettings = settings

        viewModel.model = .openAI(.gpt4o_mini)
        XCTAssertTrue(viewModel.model.generationCapabilities.supportsAnyOverride)
        viewModel.model = .claudeCode(anthropic)

        XCTAssertFalse(viewModel.model.generationCapabilities.supportsAnyOverride)
        XCTAssertEqual(viewModel.generationSettings, settings)
        viewModel.model = .openAI(.gpt4o_mini)
        XCTAssertTrue(viewModel.model.generationCapabilities.supportsAnyOverride)
        XCTAssertEqual(viewModel.generationSettings, settings)
    }
}

private final class FakeGenerationSettingsStore: ChatGenerationSettingsStoring {
    var settings: ChatGenerationSettings
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var resetCount = 0

    init(settings: ChatGenerationSettings = .automatic) {
        self.settings = settings
    }

    func load() -> ChatGenerationSettings {
        loadCount += 1
        return settings
    }

    func save(_ settings: ChatGenerationSettings) {
        saveCount += 1
        self.settings = settings
    }

    func reset() {
        resetCount += 1
        settings = .automatic
    }
}
