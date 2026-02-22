import Foundation
import LangTools
import OpenAI
import Anthropic
import XAI
import Gemini

var langToolchain = LangToolchain()
let messageService = MessageService()
let networkClient = NetworkClient.shared

@main
struct ChatCLI {
    static func main() async throws {

        // Check and request API keys if needed
        try await checkAndRequestAPIKeys(messageService: messageService)

        print("Chat CLI Started")
        print("Commands: 'exit', 'model', 'test'")
        print("Current model: \(UserDefaults.model.rawValue)")

        while true {
            print("\nYou: ".green, terminator: "")
            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }

            if input.lowercased() == "exit" {
                print("Goodbye!")
                break
            }

            if input.lowercased() == "model" {
                try await changeModel()
                continue
            }

            if input.lowercased() == "test" {
                await AgentTestRunner.runInteractiveTests(messageService: messageService)
                continue
            }

            do {
                try await messageService.performMessageCompletionRequest(message: input, stream: true)
            } catch {
                print("Error: \(error.localizedDescription)")
            }
        }
    }

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

    static func changeModel() async throws {
        print("")
        print("\nAvailable models:")
        print("1. OpenAI GPT-4o mini")
        print("2. OpenAI GPT-4o")
        print("3. Anthropic Claude 4.6 Sonnet")
        print("4. Gemini 2.5 Flash")
        print("5. XAI Grok 4")

        print("\nSelect model (1-5): ", terminator: "")
        guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        let newModel: Model? = switch choice {
            case "1": .openAI(.gpt4o_mini)
            case "2": .openAI(.gpt4o)
            case "3": .anthropic(.claude46Sonnet_latest)
            case "4": .gemini(.gemini25Flash)
            case "5": .xAI(.grok4)
            default: nil
        }
        if let newModel {
            UserDefaults.model = newModel
            print("Model changed to: \(newModel.rawValue)")
        } else {
            print("Invalid choice. Keeping current model.")
        }
    }
}

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
}
