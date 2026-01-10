import Foundation
import LangTools
import OpenAI
import Anthropic
import XAI
import Gemini
import Ollama

var langToolchain = LangToolchain()
let messageService = MessageService()
let networkClient = NetworkClient.shared

@main
struct ChatCLI {
    // MARK: - Command Structure

    struct Command {
        let name: String
        let description: String
        let action: (String) async throws -> Bool // Returns whether to continue the loop
    }

    // MARK: - Command Definitions

    private static let commands: [String: Command] = [
        "help": Command(
            name: "help",
            description: "Show available commands",
            action: showHelp
        ),
        "model": Command(
            name: "model",
            description: "Change the active model",
            action: changeModel
        ),
        "exit": Command(
            name: "exit",
            description: "Exit the application",
            action: { _ in print("Goodbye!".green); return false }
        ),
        "clear": Command(
            name: "clear",
            description: "Clear chat history",
            action: clearChat
        ),
        "info": Command(
            name: "info",
            description: "Show information about the current model",
            action: showModelInfo
        ),
        "tools": Command(
            name: "tools",
            description: "List available tools",
            action: listTools
        ),
        "save": Command(
            name: "save",
            description: "Save conversation to file",
            action: saveConversation
        ),
        "load": Command(
            name: "load",
            description: "Load conversation from file",
            action: loadConversation
        ),
        "settings": Command(
            name: "settings",
            description: "Adjust model settings",
            action: adjustSettings
        ),
        "voice": Command(
            name: "voice",
            description: "Toggle text-to-speech for responses",
            action: toggleVoice
        ),
        "test": Command(
            name: "test",
            description: "Run interactive agent tests",
            action: runTests
        )
    ]

    // MARK: - Main Entry Point

    static func main() async throws {
        // Check and request API keys if needed
        try await checkAndRequestAPIKeys(messageService: messageService)

        // Welcome display
        print("\n" + String.repeating("=", count: 50).cyan)
        print("LangTools CLI v1.0".bold.green.centered(width: 50))
        print(String.repeating("=", count: 50).cyan + "\n")

        print("Current model: \(UserDefaults.model.rawValue)".yellow)
        print("\nType a message to chat with the AI")
        print("Type /command to execute a command")
        print("Type /help to see available commands")
        print("Type /exit to quit\n")

        // Main loop with command handling
        while true {
            print("\nYou: ".green, terminator: "")
            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }

            if input.isEmpty { continue }

            // Check if input is a command
            if input.hasPrefix("/") {
                let commandInput = String(input.dropFirst())
                let components = commandInput.split(separator: " ", maxSplits: 1)
                let commandName = String(components[0])
                let args = components.count > 1 ? String(components[1]) : ""

                if let command = commands[commandName] {
                    do {
                        let shouldContinue = try await command.action(args)
                        if !shouldContinue {
                            break
                        }
                    } catch {
                        print("Error executing command: \(error.localizedDescription)".red)
                    }
                } else {
                    print("Unknown command: \(commandName)".red)
                    print("Type /help to see available commands".yellow)
                }
            } else {
                // Regular chat message
                do {
                    try await performMessageCompletionRequest(message: input, stream: true)
                } catch {
                    print("Error: \(error.localizedDescription)".red)
                }
            }
        }
    }

    // MARK: - API Key Management

    static func checkAndRequestAPIKeys(messageService: MessageService) async throws {
        for service in APIService.allCases {
            if UserDefaults.getApiKey(for: service) == nil {
                print("\nNo API key found for \(service.rawValue)")
                print("Please enter your \(service.rawValue) API key: ", terminator: "")
                if let apiKey = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    try networkClient.updateApiKey(apiKey, for: service)
                    print("\(service.rawValue) API key saved successfully")
                }
            }
        }
    }

    // MARK: - Command Implementations

    static func showHelp(_ args: String) async throws -> Bool {
        print("\nAvailable Commands:".bold.yellow)
        for (name, command) in commands.sorted(by: { $0.key < $1.key }) {
            print("  /\(name.padRight(10)) - \(command.description)")
        }
        return true
    }

    static func changeModel(_ args: String) async throws -> Bool {
        print("")
        print("\nAvailable models:")
        print("1. OpenAI GPT-3.5")
        print("2. OpenAI GPT-4")
        print("3. Anthropic Claude")
        print("4. Gemini")
        print("5. XAI")
        print("6. Ollama")

        print("\nSelect model (1-6): ", terminator: "")
        guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }

        let newModel: Model? = switch choice {
            case "1": .openAI(.gpt35Turbo)
            case "2": .openAI(.gpt4)
            case "3": .anthropic(.claude35Sonnet_20240620)
            case "4": .gemini(.gemini15FlashLatest)
            case "5": .xAI(.grok)
            case "6":
                // Display available Ollama models
                selectOllamaModel()
            default: nil
        }

        if let newModel {
            UserDefaults.model = newModel
            print("Model changed to: \(newModel.rawValue)".green)
        } else {
            print("Invalid choice. Keeping current model.".red)
        }
        return true
    }

    private static func selectOllamaModel() -> Model? {
        let ollamaModels = Model.cachedOllamaModels
        if ollamaModels.isEmpty {
            print("No Ollama models available. Please run the LangTools_Example app to configure Ollama.".red)
            return nil
        }

        print("\nAvailable Ollama models:")
        for (index, model) in ollamaModels.enumerated() {
            print("\(index + 1). \(model.rawValue)")
        }

        print("\nSelect Ollama model (1-\(ollamaModels.count)): ", terminator: "")
        if let ollamaChoice = readLine(),
           let ollamaIndex = Int(ollamaChoice),
           ollamaIndex > 0 && ollamaIndex <= ollamaModels.count {
            return .ollama(ollamaModels[ollamaIndex - 1])
        } else {
            return nil
        }
    }

    static func clearChat(_ args: String) async throws -> Bool {
        messageService.clearMessages()
        print("Chat history cleared.".green)
        return true
    }

    static func showModelInfo(_ args: String) async throws -> Bool {
        print("\nCurrent Model Information:".bold.yellow)
        print("  Model: \(UserDefaults.model.rawValue)")
        print("  Max Tokens: \(UserDefaults.maxTokens)")
        print("  Temperature: \(UserDefaults.temperature)")
        return true
    }

    static func listTools(_ args: String) async throws -> Bool {
        print("\nAvailable Tools:".bold.yellow)
        if let tools = messageService.tools, !tools.isEmpty {
            for tool in tools {
                print("  \(tool.name): \(tool.description ?? "")")
            }
        } else {
            print("  No tools available for the current model.")
        }
        return true
    }

    static func saveConversation(_ args: String) async throws -> Bool {
        let filename = args.isEmpty ? "conversation-\(Int(Date().timeIntervalSince1970)).json" : args

        // Create encoder
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        // Encode messages
        let data = try encoder.encode(messageService.messages)

        // Save to file
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        try data.write(to: fileURL)

        print("Conversation saved to \(fileURL.path)".green)
        return true
    }

    static func loadConversation(_ args: String) async throws -> Bool {
        guard !args.isEmpty else {
            print("Please specify a filename to load".red)
            return true
        }

        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(args)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("File not found: \(fileURL.path)".red)
            return true
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let messages = try decoder.decode([Message].self, from: data)

        messageService.messages = messages
        print("Loaded \(messages.count) messages from \(fileURL.path)".green)
        return true
    }

    static func adjustSettings(_ args: String) async throws -> Bool {
        if args.isEmpty {
            print("\nCurrent Settings:".bold.yellow)
            print("  1. Max Tokens: \(UserDefaults.maxTokens)")
            print("  2. Temperature: \(UserDefaults.temperature)")
            print("\nEnter setting number to change, or 'q' to quit:".yellow)

            if let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) {
                switch choice {
                case "1":
                    print("Enter new Max Tokens value (current: \(UserDefaults.maxTokens)): ".yellow, terminator: "")
                    if let input = readLine(), let value = Int(input) {
                        UserDefaults.maxTokens = value
                        print("Max Tokens updated to \(value)".green)
                    }
                case "2":
                    print("Enter new Temperature value (0.0-1.0, current: \(UserDefaults.temperature)): ".yellow, terminator: "")
                    if let input = readLine(), let value = Double(input) {
                        UserDefaults.temperature = min(max(0.0, value), 1.0)
                        print("Temperature updated to \(UserDefaults.temperature)".green)
                    }
                case "q": break
                default: print("Invalid option".red)
                }
            }
        } else {
            // Parse settings from args
            let components = args.split(separator: "=")
            if components.count == 2 {
                let setting = String(components[0]).trimmingCharacters(in: .whitespaces)
                let value = String(components[1]).trimmingCharacters(in: .whitespaces)

                switch setting.lowercased() {
                case "maxtoken", "maxtokens", "max_tokens":
                    if let intValue = Int(value) {
                        UserDefaults.maxTokens = intValue
                        print("Max Tokens updated to \(intValue)".green)
                    }
                case "temp", "temperature":
                    if let doubleValue = Double(value) {
                        UserDefaults.temperature = min(max(0.0, doubleValue), 1.0)
                        print("Temperature updated to \(UserDefaults.temperature)".green)
                    }
                default:
                    print("Unknown setting: \(setting)".red)
                }
            } else {
                print("Invalid format. Use: /settings setting=value".red)
            }
        }

        return true
    }

    static func toggleVoice(_ args: String) async throws -> Bool {
        let isEnabled = !UserDefaults.standard.bool(forKey: "voiceEnabled")
        UserDefaults.standard.set(isEnabled, forKey: "voiceEnabled")

        print("Voice output \(isEnabled ? "enabled" : "disabled")".green)
        return true
    }

    static func runTests(_ args: String) async throws -> Bool {
        await AgentTestRunner.runInteractiveTests(messageService: messageService)
        return true
    }

    // MARK: - Chat Completion

    static func performMessageCompletionRequest(message: String, stream: Bool = false) async throws {
        do {
            // Create a variable to collect the full response if voice is enabled
            var fullResponse = ""
            let voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")

            try await getChatCompletion(for: message, stream: stream, onChunk: { chunk in
                if voiceEnabled {
                    fullResponse += chunk
                }
            })

            // If voice is enabled, speak the response
            if voiceEnabled && !fullResponse.isEmpty {
                do {
                    print("\nPlaying audio response...".yellow)
                    try await networkClient.playAudio(for: fullResponse)
                } catch {
                    print("Error playing audio: \(error.localizedDescription)".red)
                }
            }
        } catch let error as LangToolsError {
            messageService.handleLangToolsError(error)
        } catch let error as LangToolsRequestError {
            messageService.handleLangToolsRequestError(error)
        } catch {
            print("Unexpected error: \(error.localizedDescription)".red)
            throw error
        }
    }

    static func getChatCompletion(for message: String, stream: Bool, onChunk: ((String) -> Void)? = nil) async throws {
        await MainActor.run {
            messageService.messages.append(Message(text: message, role: .user))
        }

        let toolChoice = (messageService.tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto
        print("\rAssistant: ".yellow, terminator: "")
        let uuid = UUID(); var content: String = ""
        let stream = try messageService.streamChatCompletionRequest(
            messages: messageService.messages,
            stream: stream,
            tools: messageService.tools,
            toolChoice: toolChoice
        )
        for try await chunk in stream {
            // hack to print new lines as long as they aren't the last one
            if content.hasSuffix("\n") {
                print("")
            }

            await MainActor.run {
                print("\(chunk.trimingTrailingNewlines())", terminator: "")
            }
            fflush(stdout)

            content += chunk
            onChunk?(chunk)  // Call the chunk handler if provided

            let message = Message(uuid: uuid, text: content.trimingTrailingNewlines(), role: .assistant)

            if let last = messageService.messages.last, last.uuid == uuid {
                messageService.messages[messageService.messages.endIndex - 1] = message
            } else {
                messageService.messages.append(message)
            }
        }

        print("") // Add a newline after the complete response
    }
}

// MARK: - ANSI Color Codes

typealias Colors = ANSIColor
enum ANSIColor: String, CaseIterable {
    case black = "\u{001B}[0;30m"
    case red = "\u{001B}[0;31m"
    case green = "\u{001B}[0;32m"
    case yellow = "\u{001B}[0;33m"
    case blue = "\u{001B}[0;34m"
    case magenta = "\u{001B}[0;35m"
    case cyan = "\u{001B}[0;36m"
    case white = "\u{001B}[0;37m"
    case `default` = "\u{001B}[0;0m"

    static func + (lhs: ANSIColor, rhs: String) -> String {
        return lhs.rawValue + rhs
    }

    static func + (lhs: String, rhs: ANSIColor) -> String {
        return lhs + rhs.rawValue
    }
}

// MARK: - String Extensions for Formatting

extension String {
    func colored(_ color: ANSIColor) -> String { return color + self + ANSIColor.default }
    var black: String { return colored(.black) }
    var red: String { return colored(.red) }
    var green: String { return colored(.green) }
    var yellow: String { return colored(.yellow) }
    var blue: String { return colored(.blue) }
    var magenta: String { return colored(.magenta) }
    var cyan: String { return colored(.cyan) }
    var white: String { return colored(.white) }

    // Text styling
    var bold: String { return "\u{001B}[1m\(self)\u{001B}[0m" }
    var underline: String { return "\u{001B}[4m\(self)\u{001B}[0m" }
    var reversed: String { return "\u{001B}[7m\(self)\u{001B}[0m" }
    var blink: String { return "\u{001B}[5m\(self)\u{001B}[0m" }

    // Background colors
    var blackBackground: String { return "\u{001B}[40m\(self)\u{001B}[0m" }
    var redBackground: String { return "\u{001B}[41m\(self)\u{001B}[0m" }
    var greenBackground: String { return "\u{001B}[42m\(self)\u{001B}[0m" }
    var yellowBackground: String { return "\u{001B}[43m\(self)\u{001B}[0m" }
    var blueBackground: String { return "\u{001B}[44m\(self)\u{001B}[0m" }
    var magentaBackground: String { return "\u{001B}[45m\(self)\u{001B}[0m" }
    var cyanBackground: String { return "\u{001B}[46m\(self)\u{001B}[0m" }
    var whiteBackground: String { return "\u{001B}[47m\(self)\u{001B}[0m" }

    // Padding and alignment
    func padRight(_ length: Int) -> String {
        if self.count >= length {
            return self
        }
        return self + String(repeating: " ", count: length - self.count)
    }

    func centered(width: Int) -> String {
        guard width > count else { return self }
        let leftPadding = (width - count) / 2
        let rightPadding = width - count - leftPadding
        return String(repeating: " ", count: leftPadding) + self + String(repeating: " ", count: rightPadding)
    }

    static func repeating(_ character: Character, count: Int) -> String {
        return String(repeating: character, count: count)
    }
}
