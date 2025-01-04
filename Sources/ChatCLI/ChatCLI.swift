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
        
        print("Chat CLI Started - Type 'exit' to quit or 'model' to change the active model")
        print("Current model: \(UserDefaults.model.rawValue)")
        
        while true {
            print(Colors.green + "You: " + Colors.reset, terminator: "")
            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }

            if input.lowercased() == "exit" {
                print("Goodbye!")
                break
            }
            
            if input.lowercased() == "model" {
                try await changeModel()
                continue
            }
            
            do {
                try await performMessageCompletionRequest(message: input, stream: true)
            } catch {
                print("Error: \(error.localizedDescription)")
            }
        }
    }

    static func checkAndRequestAPIKeys(messageService: MessageService) async throws {
        for service in LLMAPIService.allCases {
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
        print("1. OpenAI GPT-3.5")
        print("2. OpenAI GPT-4")
        print("3. Anthropic Claude")
        print("4. Gemini")
        print("5. XAI")
        
        print("\nSelect model (1-5): ", terminator: "")
        guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        let newModel: Model? = switch choice {
            case "1": .openAI(.gpt35Turbo)
            case "2": .openAI(.gpt4)
            case "3": .anthropic(.claude35Sonnet_20240620)
            case "4": .gemini(.gemini15FlashLatest)
            case "5": .xAI(.grok)
            default: nil
        }
        if let newModel {
            UserDefaults.model = newModel
            print("Model changed to: \(newModel.rawValue)")
        } else {
            print("Invalid choice. Keeping current model.")
        }
    }

    static func performMessageCompletionRequest(message: String, stream: Bool = false) async throws {
        do {
            try await getChatCompletion(for: message, stream: stream)
        } catch let error as LangToolError {
            messageService.handleLangToolError(error)
        } catch let error as LangToolsRequestError {
            messageService.handleLangToolsRequestError(error)
        } catch {
            print("Unexpected error: \(error.localizedDescription)")
            throw error
        }
    }

    static func streamChatCompletionRequest(messages: [Message], model: Model = UserDefaults.model, stream: Bool = true, tools: [OpenAI.Tool]? = nil, toolChoice: OpenAI.ChatCompletionRequest.ToolChoice? = nil) throws -> AsyncThrowingStream<String, Error> {
        return try langToolchain.stream(request: networkClient.request(messages: messages, model: model, stream: stream, tools: tools, toolChoice: toolChoice)).compactMapAsyncThrowingStream { $0.content?.text }
    }

    static func getChatCompletion(for message: String, stream: Bool) async throws {
        await MainActor.run {
            messageService.messages.append(Message(text: message, role: .user))
        }

        let toolChoice = (messageService.tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto
        print(Colors.yellow + "\rAssistant: " + Colors.reset, terminator: "")
        let uuid = UUID(); var content: String = ""
        for try await message in try streamChatCompletionRequest(
            messages: messageService.messages,
            stream: stream,
            tools: messageService.tools,
            toolChoice: toolChoice
        ) {
            await MainActor.run {
                print("\(message)", terminator: "")
            }
            fflush(stdout)

            content += message
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

struct Colors {
    static let reset = "\u{001B}[0;0m"
    static let black = "\u{001B}[0;30m"
    static let red = "\u{001B}[0;31m"
    static let green = "\u{001B}[0;32m"
    static let yellow = "\u{001B}[0;33m"
    static let blue = "\u{001B}[0;34m"
    static let magenta = "\u{001B}[0;35m"
    static let cyan = "\u{001B}[0;36m"
    static let white = "\u{001B}[0;37m"
}
