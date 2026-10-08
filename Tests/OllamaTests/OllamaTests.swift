import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LangTools
import OpenAI
@testable import TestUtils
@testable import Ollama

class OllamaTests: XCTestCase {
    var api: Ollama!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = Ollama(baseURL: URL(string: "http://localhost:11434")!).configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.resetHandlers()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }


    func testOriginalInitializerFunctionTypesRemainAvailable() {
        let configurationInitializer: (URL, URLSession) -> Ollama.OllamaConfiguration = Ollama.OllamaConfiguration.init
        let ollamaInitializer: (URL, URLSession) -> Ollama = Ollama.init
        let baseURL = URL(string: "http://localhost:11434")!
        let session = URLSession(configuration: .ephemeral)

        XCTAssertEqual(configurationInitializer(baseURL, session).baseURL, baseURL)
        XCTAssertEqual(ollamaInitializer(baseURL, session).configuration.baseURL, baseURL)
    }

    func testPrepareAddsBearerAuthorizationWhenConfigured() throws {
        let authenticatedAPI = Ollama(
            baseURL: URL(string: "https://ollama.com")!,
            apiKey: "test-api-key"
        )

        let request = try authenticatedAPI.prepare(request: Ollama.VersionRequest())

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
    }

    func testPrepareOmitsEmptyAuthorization() throws {
        let request = try Ollama(apiKey: "").prepare(request: Ollama.VersionRequest())

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPrepareOmitsAuthorizationByDefault() throws {
        let request = try api.prepare(request: Ollama.VersionRequest())

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testGenerate() async throws {
        MockURLProtocol.setHandler(for: Ollama.GenerateRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "generate_response-ollama")!), 200)
        }

        let response = try await api.generate(
            model: "llama3.2",
            prompt: "Why is the sky blue?"
        )

        XCTAssertEqual(response.model, "llama3.2")
        XCTAssertFalse(response.response.isEmpty)
        XCTAssertTrue(response.done)
        XCTAssertEqual(response.context, [1, 2, 3])
        XCTAssertEqual(response.total_duration, 4935886791)
        XCTAssertEqual(response.load_duration, 534986708)
        XCTAssertEqual(response.prompt_eval_count, 26)
        XCTAssertEqual(response.prompt_eval_duration, 107345000)
        XCTAssertEqual(response.eval_count, 237)
        XCTAssertEqual(response.eval_duration, 4289432000)
    }

    func testGenerateWithOptions() async throws {
        MockURLProtocol.setHandler(for: Ollama.GenerateRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")

            return (.success(try self.getData(filename: "generate_response-ollama")!), 200)
        }

        let options = Ollama.GenerateOptions(
            seed: 42,
            top_p: 0.9,
            temperature: 0.8
        )

        let response = try await api.generate(
            model: "llama3.2",
            prompt: "Why is the sky blue?",
            options: options
        )

        XCTAssertTrue(response.done)
    }

    func testStreamGenerate() async throws {
        MockURLProtocol.setHandler(for: Ollama.GenerateRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")

            return (.success(try self.getData(filename: "generate_stream_response-ollama", fileExtension: "txt")!), 200)
        }

        var fullResponse = ""
        var results: [Ollama.GenerateResponse] = []

        for try await response in api.streamGenerate(
            model: "llama3.2",
            prompt: "Why is the sky blue?"
        ) {
            results.append(response)
            fullResponse += response.response
        }

        // Verify we got the expected number of responses
        XCTAssertEqual(results.count, 5)

        // Verify model name consistency
        results.forEach { response in
            XCTAssertEqual(response.model, "llama3.2")
        }

        // Initial responses should have:
        // - model, created_at, response, done = false
        for i in 0..<4 {
            XCTAssertFalse(results[i].done)
            XCTAssertNotNil(results[i].created_at)
            XCTAssertFalse(results[i].response.isEmpty)

            // Should not have metadata fields
            XCTAssertNil(results[i].context)
            XCTAssertNil(results[i].total_duration)
            XCTAssertNil(results[i].eval_count)
        }

        // Final response should have complete metadata
        let finalResponse = results.last!
        XCTAssertTrue(finalResponse.done)
        XCTAssertNotNil(finalResponse.context)
        XCTAssertEqual(finalResponse.context!, [1, 2, 3])
        XCTAssertEqual(finalResponse.total_duration, 10706818083)
        XCTAssertEqual(finalResponse.load_duration, 6338219291)
        XCTAssertEqual(finalResponse.prompt_eval_count, 26)
        XCTAssertEqual(finalResponse.prompt_eval_duration, 130079000)
        XCTAssertEqual(finalResponse.eval_count, 259)
        XCTAssertEqual(finalResponse.eval_duration, 4232710000)

        // Verify the full response was assembled correctly
        XCTAssertEqual(fullResponse, "The sky is blue because of Rayleigh scattering.")
    }

    func testGenerateWithStructuredOutput() async throws {
        // Test format parameter with JSON schema
        let format = Ollama.GenerateFormat.SchemaFormat(
            type: "object",
            properties: [
                "age": .init(type: "integer", description: "Age of the person"),
                "available": .init(type: "boolean", description: "If the person is available")
            ],
            required: ["age", "available"]
        )

        MockURLProtocol.setHandler(for: Ollama.GenerateRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            //               let decoded = try JSONDecoder().decode(Ollama.GenerateRequest.self, from: request.httpBody!)
            //               XCTAssertNotNil(decoded.format)
            return (.success(try self.getData(filename: "generate_response-ollama")!), 200)
        }

        let response = try await api.generate(
            model: "llama3.2",
            prompt: "Ollama is 22 years old and is busy saving the world. Respond using JSON",
            format: .schema(format)
        )

        XCTAssertTrue(response.done)
    }

    func testListModels() async throws {
        MockURLProtocol.setHandler(for: Ollama.ListModelsRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (.success(try self.getData(filename: "list_models_response-ollama")!), 200)
        }

        let response = try await api.listModels()
        XCTAssertEqual(response.models.count, 2)

        let firstModel = response.models[0]
        XCTAssertEqual(firstModel.name, "codellama:13b")
        XCTAssertEqual(firstModel.size, 7365960935)
        XCTAssertEqual(firstModel.details.family, "llama")
        XCTAssertEqual(firstModel.details.parameterSize, "13B")
        XCTAssertEqual(firstModel.details.quantizationLevel, "Q4_0")

        let secondModel = response.models[1]
        XCTAssertEqual(secondModel.name, "llama3:latest")
        XCTAssertEqual(secondModel.size, 3825819519)
        XCTAssertEqual(secondModel.details.family, "llama")
        XCTAssertEqual(secondModel.details.parameterSize, "7B")
    }

    func testListModelsError() async throws {
        MockURLProtocol.setHandler(for: Ollama.ListModelsRequest.endpoint) { _ in
            return (.success(try self.getData(filename: "error")!), 404)
        }

        do {
            _ = try await api.listModels()
            XCTFail("Expected error to be thrown")
        } catch let error as LangToolsError {
            if case .responseUnsuccessful(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 404)
            } else {
                XCTFail("Unexpected error type")
            }
        }
    }

    func testListRunningModels() async throws {
        MockURLProtocol.setHandler(for: Ollama.ListRunningModelsRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (.success(try self.getData(filename: "list_running_models_response")!), 200)
        }

        let response = try await api.listRunningModels()
        XCTAssertEqual(response.models.count, 1)

        let model = response.models[0]
        XCTAssertEqual(model.name, "mistral:latest")
        XCTAssertEqual(model.size, 5137025024)
        XCTAssertEqual(model.details.family, "llama")
        XCTAssertEqual(model.details.parameterSize, "7.2B")
        XCTAssertEqual(model.details.quantizationLevel, "Q4_0")
        XCTAssertEqual(model.sizeVRAM, 5137025024)
    }

    func testShowModel() async throws {
        MockURLProtocol.setHandler(for: Ollama.ShowModelRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "show_model_response")!), 200)
        }

        let response = try await api.showModel("mistral:latest")
        XCTAssertFalse(response.modelfile.isEmpty)
        XCTAssertEqual(response.parameters, "num_ctx 4096")
        XCTAssertEqual(response.details.family, "llama")
        XCTAssertEqual(response.details.parameterSize, "7B")
        XCTAssertEqual(response.details.quantizationLevel, "Q4_0")
        XCTAssertEqual(response.modelInfo["architecture"]?.stringValue, "llama")
        XCTAssertEqual(response.modelInfo["vocab_size"]?.intValue, 32000)
    }

    func testDeleteModel() async throws {
        MockURLProtocol.setHandler(for: Ollama.DeleteModelRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (.success(try self.getData(filename: "success_response")!), 200)
        }

        let response = try await api.deleteModel("mistral:latest")
        XCTAssertEqual(response.status, "success")
    }

    func testCopyModel() async throws {
        MockURLProtocol.setHandler(for: Ollama.CopyModelRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "success_response")!), 200)
        }

        let response = try await api.copyModel(source: "llama2", destination: "llama2-backup")
        XCTAssertEqual(response.status, "success")
    }


    func testPullModel() async throws {
        MockURLProtocol.setHandler(for: Ollama.PullModelRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "pull_model_response")!), 200)
        }

        let response = try await api.pullModel("llama2")
        XCTAssertEqual(response.status, "downloading model")
        XCTAssertEqual(response.total, 5137025024)
        XCTAssertEqual(response.completed, 2568512512)
    }

    func testStreamPullModel() async throws {
        MockURLProtocol.setHandler(for: Ollama.PullModelRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            // XCTAssertTrue(try JSONDecoder().decode(Ollama.PullModelRequest.self, from: request.httpBody!).stream ?? false)
            return (.success(try self.getData(filename: "pull_model_stream_response", fileExtension: "txt")!), 200)
        }

        var results: [Ollama.PullModelResponse] = []
        for try await response in api.streamPullModel("llama2") {
            results.append(response)
        }

        XCTAssertEqual(results.count, 8)

        // Check manifest phase
        XCTAssertEqual(results[0].status, "pulling manifest")

        // Check initial download phase
        XCTAssertEqual(results[1].status, "downloading sha256:2ae6f6dd7a3dd734790bbbf58b8909a606e0e7e97e94b7604e0aa7ae4490e6d8")
        XCTAssertEqual(results[1].total, 2142590208)
        XCTAssertNil(results[1].completed)

        // Check download progress
        XCTAssertEqual(results[2].status, "downloading sha256:2ae6f6dd7a3dd734790bbbf58b8909a606e0e7e97e94b7604e0aa7ae4490e6d8")
        XCTAssertEqual(results[2].total, 2142590208)
        XCTAssertEqual(results[2].completed, 241970)

        // Check final download progress
        XCTAssertEqual(results[3].status, "downloading sha256:2ae6f6dd7a3dd734790bbbf58b8909a606e0e7e97e94b7604e0aa7ae4490e6d8")
        XCTAssertEqual(results[3].total, 2142590208)
        XCTAssertEqual(results[3].completed, 1071295104)

        // Check final phases
        XCTAssertEqual(results[4].status, "verifying sha256 digest")
        XCTAssertEqual(results[5].status, "writing manifest")
        XCTAssertEqual(results[6].status, "removing any unused layers")
        XCTAssertEqual(results[7].status, "success")
    }

    func testPushModel() async throws {
        MockURLProtocol.setHandler(for: Ollama.PushModelRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "push_model_response")!), 200)
        }

        let response = try await api.pushModel("namespace/llama2:latest")
        XCTAssertEqual(response.status, "pushing model")
        XCTAssertEqual(response.total, 1928429856)
    }

    func testStreamPushModel() async throws {
        MockURLProtocol.setHandler(for: Ollama.PushModelRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            // XCTAssertTrue(try JSONDecoder().decode(Ollama.PushModelRequest.self, from: request.httpBody!).stream ?? false)
            return (.success(try self.getData(filename: "push_model_stream_response", fileExtension: "txt")!), 200)
        }

        var results: [Ollama.PushModelResponse] = []
        for try await response in api.streamPushModel("mattw/pygmalion:latest") {
            results.append(response)
        }

        XCTAssertEqual(results.count, 6)

        // Check initial phase
        XCTAssertEqual(results[0].status, "retrieving manifest")

        // Check upload start
        XCTAssertEqual(results[1].status, "starting upload")
        XCTAssertEqual(results[1].digest, "sha256:bc07c81de745696fdf5afca05e065818a8149fb0c77266fb584d9b2cba3711ab")
        XCTAssertEqual(results[1].total, 1928429856)

        // Check upload progress
        XCTAssertEqual(results[2].status, "uploading")

        // Check final upload progress
        XCTAssertEqual(results[3].status, "uploading")

        // Check final phases
        XCTAssertEqual(results[4].status, "pushing manifest")
        XCTAssertEqual(results[5].status, "success")
    }

    func testCreateModel() async throws {
        MockURLProtocol.setHandler(for: Ollama.CreateModelRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "success_response")!), 200)
        }

        let response = try await api.createModel(model: "custom-model", modelfile: "FROM llama2\nSYSTEM You are a helpful assistant.")
        XCTAssertEqual(response.status, "success")
    }

    func testChatRequestFactoryPreservesNativeToolCallHistory() throws {
        let toolCall = Ollama.ChatToolCall(function: .init(
            name: "calculate",
            arguments: ["expression": .string("1+1")]
        ))
        let messages = [
            Ollama.Message(role: .assistant, content: "Let me check.", tool_calls: [toolCall]),
            Ollama.Message(role: .tool, content: "2")
        ]

        let genericRequest = try Ollama.chatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: messages,
            tools: nil,
            responseSchema: nil,
            toolEventHandler: { _ in }
        )
        let request = try XCTUnwrap(genericRequest as? Ollama.ChatRequest)

        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages[0].tool_calls?.first?.name, "calculate")
        XCTAssertEqual(request.messages[0].tool_calls?.first?.function.arguments["expression"]?.stringValue, "1+1")
        XCTAssertEqual(request.messages[1].role, .tool)
        XCTAssertEqual(request.messages[1].content.text, "2")
    }

    func testChat() async throws {
        MockURLProtocol.setHandler(for: Ollama.ChatRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "chat_response-ollama")!), 200)
        }

        let response = try await api.chat(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [.init(role: .user, content: "Hello!")]
        )

        XCTAssertEqual(response.model, "llama3.2")
        XCTAssertFalse(response.content?.string?.isEmpty ?? true)
        XCTAssertTrue(response.done)
        XCTAssertEqual(response.eval_count, 298)
        XCTAssertEqual(response.eval_duration, 4799921000)
    }

    func testStreamChat() async throws {
        MockURLProtocol.setHandler(for: Ollama.ChatRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "chat_response_stream-ollama", fileExtension: "txt")!), 200)
        }

        var fullResponse = ""
        var results: [Ollama.ChatResponse] = []

        for try await response in api.streamChat(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [.init(role: .user, content: "Why is the sky blue?")]
        ) {
            results.append(response)
            if let message = response.message {
                fullResponse += message.content.text
            }
        }

        // Verify we got the expected number of responses
        XCTAssertEqual(results.count, 5)

        // Verify consistent model name
        results.forEach { response in
            XCTAssertEqual(response.model, "llama3.2")
        }

        // Initial responses should have message content but not be done
        for i in 0..<4 {
            XCTAssertFalse(results[i].done)
            XCTAssertNotNil(results[i].created_at)
            XCTAssertNotNil(results[i].message)
            XCTAssertFalse(results[i].message?.content.text.isEmpty ?? true)

            // Should not have metadata fields
            XCTAssertNil(results[i].total_duration)
            XCTAssertNil(results[i].eval_count)
        }

        // Final response should have complete metadata
        let finalResponse = results.last!
        XCTAssertTrue(finalResponse.done)
        XCTAssertEqual(finalResponse.total_duration, 10706818083)
        XCTAssertEqual(finalResponse.load_duration, 6338219291)
        XCTAssertEqual(finalResponse.prompt_eval_count, 26)
        XCTAssertEqual(finalResponse.prompt_eval_duration, 130079000)
        XCTAssertEqual(finalResponse.eval_count, 259)
        XCTAssertEqual(finalResponse.eval_duration, 4232710000)

        // Verify full response text was assembled correctly
        XCTAssertEqual(fullResponse, "The sky is blue because of Rayleigh scattering.")
    }

    func testChatWithTools() async throws {
        MockURLProtocol.setHandler(for: Ollama.ChatRequest.endpoint) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "chat_response_with_tools-ollama")!), 200)
        }

        let tools: [OpenAI.Tool] = [.init(
            name: "get_current_weather",
            description: "Get the current weather",
            tool_schema: .init(
                properties: [
                    "location": .init(
                        type: "string",
                        description: "The city and state, e.g. San Francisco, CA"),
                    "format": .init(
                        type: "string",
                        enumValues: ["celsius", "fahrenheit"],
                        description: "The temperature unit to use")
                ],
                required: ["location", "format"]))]

        let response = try await api.chat(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [.init(role: .user, content: "What's the weather in Paris?")],
            options: nil,
            tools: tools
        )

        XCTAssertEqual(response.model, "llama3.2")
        XCTAssertTrue(response.done)
        XCTAssertNotNil(response.message?.tool_calls)
        XCTAssertEqual(response.message?.tool_calls?.first?.function.name, "get_current_weather")
    }

    func testChatDecodesMixedTypeToolArguments() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.ChatRequest.endpoint] = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "chat_response_with_mixed_tool_args-ollama")!), 200)
        }

        let response = try await api.chat(
            model: OllamaModel(rawValue: "llama3.2:latest")!,
            messages: [.init(role: .user, content: "hi")],
            options: nil,
            tools: nil
        )

        let toolCall = try XCTUnwrap(response.message?.tool_calls?.first)
        XCTAssertEqual(toolCall.function.name, "ask_user_question")
        XCTAssertEqual(toolCall.function.arguments["question"]?.stringValue, "What is your name?")
        XCTAssertEqual(toolCall.function.arguments["multiSelect"]?.boolValue, false)
        XCTAssertEqual(toolCall.function.arguments["options"]?.arrayValue?.count, 0)

        let serializedArguments = try XCTUnwrap(toolCall.arguments.data(using: .utf8))
        let decodedArguments = try JSONSerialization.jsonObject(with: serializedArguments) as? [String: Any]
        XCTAssertEqual(decodedArguments?["multiSelect"] as? Bool, false)
        XCTAssertEqual((decodedArguments?["options"] as? [Any])?.count, 0)
    }

    func testVersion() async throws {
        MockURLProtocol.setHandler(for: Ollama.VersionRequest.endpoint) { request in
            // Verify request
            XCTAssertEqual(request.httpMethod, "GET")
            return (.success(try self.getData(filename: "version_response-ollama")!), 200)
        }

        let response = try await api.version()
        XCTAssertEqual(response.version, "0.5.1")
    }

    func testVersionError() async throws {
        MockURLProtocol.setHandler(for: Ollama.VersionRequest.endpoint) { _ in
            return (.success(try self.getData(filename: "error")!), 404)
        }

        do {
            _ = try await api.version()
            XCTFail("Expected error to be thrown")
        } catch let error as LangToolsError {
            if case .responseUnsuccessful(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 404)
            } else {
                XCTFail("Unexpected error type")
            }
        }
    }

    // MARK: - Structured Output Tests (lossless JSONSchema)

    func testChatRequestFactoryEncodesSchemaLosslessly() throws {
        let schema = JSONSchema.object(
            properties: [
                "name": .string(description: "The person's name"),
                "age": .integer(description: "The person's age")
            ],
            required: ["name", "age"],
            additionalProperties: .bool(false)
        )

        let request = try Ollama.chatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: [Ollama.Message(role: .user, content: "Hello")],
            tools: nil,
            responseSchema: schema,
            toolEventHandler: { _ in }
        )

        let chatRequest = try XCTUnwrap(request as? Ollama.ChatRequest)
        guard case .jsonSchema(let stored) = chatRequest.format else {
            XCTFail("Expected .jsonSchema format, got \(String(describing: chatRequest.format))")
            return
        }
        // Lossless: full JSONSchema equality
        XCTAssertEqual(stored, schema)
    }

    func testResponseSchemaRoundtripIdentity() throws {
        let schema = JSONSchema.object(
            properties: [
                "city": .string(description: "City name"),
                "temp": .number(description: "Temperature", minimum: -100, maximum: 60)
            ],
            required: ["city"],
            additionalProperties: .bool(false)
        )

        var request = Ollama.ChatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: [Ollama.Message(role: .user, content: "Weather?")],
            format: nil
        )
        request.responseSchema = schema
        let roundtripped = try XCTUnwrap(request.responseSchema)
        XCTAssertEqual(roundtripped, schema, "Full schema must survive roundtrip identically")
    }

    func testNestedObjectSchemaPreserved() throws {
        let schema = JSONSchema.object(
            properties: [
                "event": .object(
                    properties: [
                        "title": .string(),
                        "location": .object(
                            properties: [
                                "lat": .number(),
                                "lng": .number()
                            ],
                            required: ["lat", "lng"]
                        )
                    ],
                    required: ["title", "location"]
                )
            ],
            required: ["event"]
        )

        var request = Ollama.ChatRequest(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [Ollama.Message(role: .user, content: "Event?")],
            format: nil
        )
        request.responseSchema = schema

        // Roundtrip
        let roundtripped = try XCTUnwrap(request.responseSchema)
        XCTAssertEqual(roundtripped, schema)

        // Verify nested structure survived
        let eventSchema = try XCTUnwrap(roundtripped.properties?["event"])
        XCTAssertEqual(eventSchema.type, .object)
        let locationSchema = try XCTUnwrap(eventSchema.properties?["location"])
        XCTAssertEqual(locationSchema.type, .object)
        XCTAssertEqual(locationSchema.required, ["lat", "lng"])
    }

    func testArrayWithItemsSchemaPreserved() throws {
        let schema = JSONSchema.object(
            properties: [
                "attendees": .array(
                    items: .object(
                        properties: [
                            "name": .string(),
                            "email": .string(format: .email)
                        ],
                        required: ["name"]
                    )
                )
            ],
            required: ["attendees"]
        )

        var request = Ollama.ChatRequest(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [Ollama.Message(role: .user, content: "Attendees?")],
            format: nil
        )
        request.responseSchema = schema

        let roundtripped = try XCTUnwrap(request.responseSchema)
        XCTAssertEqual(roundtripped, schema)

        let attendeesSchema = try XCTUnwrap(roundtripped.properties?["attendees"])
        XCTAssertEqual(attendeesSchema.type, .array)
        let itemSchema = try XCTUnwrap(attendeesSchema.items)
        XCTAssertEqual(itemSchema.type, .object)
        XCTAssertEqual(itemSchema.required, ["name"])
        XCTAssertEqual(itemSchema.properties?["email"]?.format, .email)
    }

    func testAnyOfNullableSchemaPreserved() throws {
        let schema = JSONSchema.object(
            properties: [
                "description": .anyOf([.string(), .null()], description: "Optional description")
            ],
            required: []
        )

        var request = Ollama.ChatRequest(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [Ollama.Message(role: .user, content: "Test")],
            format: nil
        )
        request.responseSchema = schema

        let roundtripped = try XCTUnwrap(request.responseSchema)
        XCTAssertEqual(roundtripped, schema)

        let desc = try XCTUnwrap(roundtripped.properties?["description"])
        XCTAssertNil(desc.type, "anyOf schemas have nil type")
        XCTAssertEqual(desc.anyOf?.count, 2)
        XCTAssertEqual(desc.anyOf?[0].type, .string)
        XCTAssertEqual(desc.anyOf?[1].type, .null)
    }

    func testEnumAndConstraintsSchemaPreserved() throws {
        let schema = JSONSchema.object(
            properties: [
                "role": .string(enumValues: ["admin", "user", "guest"]),
                "score": .integer(minimum: 0, maximum: 100),
                "email": .string(description: nil, enumValues: nil, minLength: 5, maxLength: 254, pattern: "^.+@.+$", format: .email)
            ],
            required: ["role", "score"]
        )

        var request = Ollama.ChatRequest(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [Ollama.Message(role: .user, content: "Test")],
            format: nil
        )
        request.responseSchema = schema

        let roundtripped = try XCTUnwrap(request.responseSchema)
        XCTAssertEqual(roundtripped, schema)

        // Verify constraints survived
        let roleSchema = try XCTUnwrap(roundtripped.properties?["role"])
        XCTAssertEqual(roleSchema.enumValues, ["admin", "user", "guest"])

        let scoreSchema = try XCTUnwrap(roundtripped.properties?["score"])
        XCTAssertEqual(scoreSchema.minimum, 0)
        XCTAssertEqual(scoreSchema.maximum, 100)

        let emailSchema = try XCTUnwrap(roundtripped.properties?["email"])
        XCTAssertEqual(emailSchema.format, .email)
        XCTAssertEqual(emailSchema.minLength, 5)
        XCTAssertEqual(emailSchema.maxLength, 254)
        XCTAssertEqual(emailSchema.pattern, "^.+@.+$")
    }

    func testAdditionalPropertiesFalsePreserved() throws {
        let schema = JSONSchema.object(
            properties: ["name": .string()],
            required: ["name"],
            additionalProperties: .bool(false)
        )

        var request = Ollama.ChatRequest(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [Ollama.Message(role: .user, content: "Test")],
            format: nil
        )
        request.responseSchema = schema

        let roundtripped = try XCTUnwrap(request.responseSchema)
        XCTAssertEqual(roundtripped.additionalProperties, .bool(false))
        XCTAssertEqual(roundtripped, schema)
    }

    func testEncodeDecodeEqualityPreservesFullSchema() throws {
        let schema = JSONSchema.object(
            properties: [
                "items": .array(
                    items: .object(
                        properties: [
                            "id": .integer(),
                            "tags": .array(items: .string(), minItems: 1, uniqueItems: true),
                            "meta": .anyOf([.object(properties: ["key": .string()]), .null()])
                        ],
                        required: ["id"]
                    )
                )
            ],
            required: ["items"],
            additionalProperties: .bool(false)
        )

        var request = Ollama.ChatRequest(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [Ollama.Message(role: .user, content: "Complex")],
            format: nil
        )
        request.responseSchema = schema

        // Encode → decode → verify equality
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Ollama.ChatRequest.self, from: data)

        let recovered = try XCTUnwrap(decoded.responseSchema)
        XCTAssertEqual(recovered, schema, "Full schema must survive encode→decode identically")
    }

    func testToolContinuationRetainsFullSchema() throws {
        let schema = JSONSchema.object(
            properties: [
                "results": .array(
                    items: .object(
                        properties: [
                            "title": .string(),
                            "confidence": .number(minimum: 0, maximum: 1)
                        ],
                        required: ["title"]
                    )
                )
            ],
            required: ["results"],
            additionalProperties: .bool(false)
        )

        let tools: [OpenAI.Tool] = [.init(
            name: "search",
            description: "Search",
            tool_schema: .init(properties: ["q": .init(type: "string", description: "Query")], required: ["q"])
        )]

        let request = try Ollama.chatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: [Ollama.Message(role: .user, content: "Find")],
            tools: tools.map { $0 as any LangToolsTool },
            responseSchema: schema,
            toolEventHandler: { _ in }
        )

        let chatRequest = try XCTUnwrap(request as? Ollama.ChatRequest)
        XCTAssertNotNil(chatRequest.tools)
        guard case .jsonSchema(let stored) = chatRequest.format else {
            XCTFail("Full schema must survive alongside tools")
            return
        }
        XCTAssertEqual(stored, schema)
        let recovered = try XCTUnwrap(chatRequest.responseSchema)
        XCTAssertEqual(recovered, schema)
    }

    func testResponseSchemaClearingLeavesPlainJsonUntouched() throws {
        var request = Ollama.ChatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: [Ollama.Message(role: .user, content: "Hi")],
            format: .json
        )
        XCTAssertEqual(request.format, .json)
        request.responseSchema = nil
        XCTAssertEqual(request.format, .json, "Plain json format should survive nil responseSchema")
    }

    func testResponseSchemaSetThenClear() throws {
        let schema = JSONSchema.object(properties: ["x": .integer()])
        var request = Ollama.ChatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: [Ollama.Message(role: .user, content: "Hi")],
            format: nil
        )
        request.responseSchema = schema
        XCTAssertNotNil(request.responseSchema)
        request.responseSchema = nil
        XCTAssertNil(request.responseSchema)
        XCTAssertNil(request.format)
    }

    func testPlainJsonFormatBackwardCompatible() throws {
        var request = Ollama.ChatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: [Ollama.Message(role: .user, content: "Hi")],
            format: .json
        )
        XCTAssertNil(request.responseSchema)
        let schema = JSONSchema.object(properties: ["x": .integer()])
        request.responseSchema = schema
        guard case .jsonSchema = request.format else {
            XCTFail("Should switch to jsonSchema format")
            return
        }
    }

    func testChatRequestWithoutSchemaHasNilResponseSchema() throws {
        let request = Ollama.ChatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: [Ollama.Message(role: .user, content: "Hi")],
            format: nil
        )
        XCTAssertNil(request.responseSchema)
        XCTAssertNil(request.format)
    }

    func testPerformTypedDecode() async throws {
        struct Person: StructuredOutput, Equatable {
            let name: String
            let age: Int
            static var jsonSchema: JSONSchema {
                .object(properties: ["name": .string(), "age": .integer()], required: ["name", "age"])
            }
        }
        let responseJSON = #"{"name":"Alice","age":30}"#
        let chatResponse = Ollama.ChatResponse(
            model: "llama3.2", created_at: "2025-01-01T00:00:00Z",
            message: Ollama.Message(role: .assistant, content: responseJSON),
            done: true, done_reason: "stop",
            total_duration: nil, load_duration: nil, prompt_eval_count: nil,
            prompt_eval_duration: nil, eval_count: nil, eval_duration: nil
        )
        let person: Person = try chatResponse.structuredOutput()
        XCTAssertEqual(person.name, "Alice")
        XCTAssertEqual(person.age, 30)
    }

    func testPerformTypedDecodeWithInvalidJSONThrows() {
        let chatResponse = Ollama.ChatResponse(
            model: "llama3.2", created_at: "2025-01-01T00:00:00Z",
            message: Ollama.Message(role: .assistant, content: "not json"),
            done: true, done_reason: "stop",
            total_duration: nil, load_duration: nil, prompt_eval_count: nil,
            prompt_eval_duration: nil, eval_count: nil, eval_duration: nil
        )
        struct Person: StructuredOutput, Equatable {
            let name: String; let age: Int
            static var jsonSchema: JSONSchema {
                .object(properties: ["name": .string(), "age": .integer()], required: ["name", "age"])
            }
        }
        XCTAssertThrowsError(try chatResponse.structuredOutput(as: Person.self))
    }

    func testJsonContentReturnsNilForMissingMessage() {
        let response = Ollama.ChatResponse(
            model: "llama3.2", created_at: "2025-01-01T00:00:00Z",
            message: nil, done: true, done_reason: nil,
            total_duration: nil, load_duration: nil, prompt_eval_count: nil,
            prompt_eval_duration: nil, eval_count: nil, eval_duration: nil
        )
        XCTAssertNil(response.jsonContent)
    }

    func testJsonContentReturnsMessageText() {
        let response = Ollama.ChatResponse(
            model: "llama3.2", created_at: "2025-01-01T00:00:00Z",
            message: Ollama.Message(role: .assistant, content: #"{"key":"value"}"#),
            done: true, done_reason: "stop",
            total_duration: nil, load_duration: nil, prompt_eval_count: nil,
            prompt_eval_duration: nil, eval_count: nil, eval_duration: nil
        )
        XCTAssertEqual(response.jsonContent, #"{"key":"value"}"#)
    }

    func testLocalModelSchemaAcceptedByFactory() throws {
        // Schema is accepted client-side for local models; server decides
        // actual structured-output support.
        let schema = JSONSchema.object(properties: ["result": .string()])
        let request = try Ollama.chatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: [Ollama.Message(role: .user, content: "Test")],
            tools: nil,
            responseSchema: schema,
            toolEventHandler: { _ in }
        )
        let chatRequest = try XCTUnwrap(request as? Ollama.ChatRequest)
        XCTAssertNotNil(chatRequest.responseSchema, "Local model should accept schema client-side")
    }

    func testCloudModelSchemaAcceptedByFactory() throws {
        // Cloud models go through the same factory without artificial guard.
        let schema = JSONSchema.object(properties: ["result": .string()])
        let request = try Ollama.chatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "glm-5.2:cloud")),
            messages: [Ollama.Message(role: .user, content: "Test")],
            tools: nil,
            responseSchema: schema,
            toolEventHandler: { _ in }
        )
        let chatRequest = try XCTUnwrap(request as? Ollama.ChatRequest)
        XCTAssertTrue(chatRequest.model.isCloudModel)
        XCTAssertNotNil(chatRequest.responseSchema, "Cloud model should accept schema; server decides support")
    }

    func testWireFormatEncodesFullJSONSchema() throws {
        let schema = JSONSchema.object(
            properties: [
                "events": .array(
                    items: .object(
                        properties: [
                            "title": .string(),
                            "recurring": .boolean()
                        ],
                        required: ["title"]
                    )
                )
            ],
            required: ["events"],
            additionalProperties: .bool(false)
        )
        var request = Ollama.ChatRequest(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [Ollama.Message(role: .user, content: "Events")],
            format: nil
        )
        request.responseSchema = schema

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json: [String: Any] = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let format: [String: Any] = try XCTUnwrap(json["format"] as? [String: Any])

        // Top-level shape
        XCTAssertEqual(format["type"] as? String, "object")
        XCTAssertEqual(format["additionalProperties"] as? Bool, false)

        // Nested array→items survives
        let props: [String: [String: Any]] = try XCTUnwrap(format["properties"] as? [String: [String: Any]])
        let events: [String: Any] = try XCTUnwrap(props["events"])
        XCTAssertEqual(events["type"] as? String, "array")
        let items: [String: Any] = try XCTUnwrap(events["items"] as? [String: Any])
        XCTAssertEqual(items["type"] as? String, "object")
        XCTAssertEqual(items["required"] as? [String], ["title"])
    }

    func testPlainJsonRequestEncodesAsString() throws {
        var request = Ollama.ChatRequest(
            model: try XCTUnwrap(Ollama.Model(rawValue: "llama3.2")),
            messages: [Ollama.Message(role: .user, content: "Hi")],
            format: .json
        )
        request.responseSchema = nil

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json: [String: Any] = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "json")
    }

    // MARK: - Legacy .schema(SchemaFormat) backward compatibility

    func testLegacySchemaFormatSurvivesEncodeDecodeIdentity() throws {
        // Construct a simple schema using legacy .schema(SchemaFormat).
        // After encode→decode it MUST remain .schema(SchemaFormat),
        // not be normalized to .jsonSchema.
        let format = Ollama.GenerateFormat.schema(.init(
            type: "object",
            properties: [
                "name": .init(type: "string", description: "The name"),
                "count": .init(type: "integer", description: "Item count")
            ],
            required: ["name"]
        ))
        var request = Ollama.ChatRequest(
            model: OllamaModel(rawValue: "llama3.2")!,
            messages: [Ollama.Message(role: .user, content: "Hi")],
            format: format
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let decoded = try JSONDecoder().decode(Ollama.ChatRequest.self, from: data)

        // Must still be .schema after roundtrip
        guard case .schema(let recovered) = decoded.format else {
            XCTFail("Legacy .schema format must survive encode→decode as .schema, got \(String(describing: decoded.format))")
            return
        }
        XCTAssertEqual(recovered.type, "object")
        XCTAssertEqual(recovered.properties["name"]?.type, "string")
        XCTAssertEqual(recovered.properties["count"]?.type, "integer")
        XCTAssertEqual(recovered.required, ["name"])

        // responseSchema getter should recover semantically from .schema
        let recoveredSchema = try XCTUnwrap(decoded.responseSchema)
        XCTAssertEqual(recoveredSchema.type, .object)
        XCTAssertEqual(recoveredSchema.required, ["name"])
        XCTAssertEqual(recoveredSchema.properties?["name"]?.type, .string)
    }

    func testLegacySchemaWithSimpleDescriptionDecodesAsSchema() throws {
        // A JSON object with only type+properties+required (and property
        // values having only type+description) must decode as .schema.
        let rawJSON = """
        {"type":"object","properties":{"x":{"type":"integer","description":"A number"}},"required":["x"]}
        """
        let data = Data(rawJSON.utf8)
        let format = try JSONDecoder().decode(Ollama.GenerateFormat.self, from: data)
        guard case .schema(let sf) = format else {
            XCTFail("Simple flat schema must decode as .schema, got \(format)")
            return
        }
        XCTAssertEqual(sf.type, "object")
        XCTAssertEqual(sf.properties["x"]?.type, "integer")
    }

    func testLegacyFirstNeverStripsExtras() throws {
        // A flat schema with an extra field (additionalProperties)
        // that SchemaFormat doesn't know about MUST decode as .jsonSchema
        // so the extra constraint is preserved.
        let rawJSON = """
        {"type":"object","properties":{"x":{"type":"integer","description":"A number"}},"required":["x"],"additionalProperties":false}
        """
        let data = Data(rawJSON.utf8)
        let format = try JSONDecoder().decode(Ollama.GenerateFormat.self, from: data)
        guard case .jsonSchema(let schema) = format else {
            XCTFail("Schema with additionalProperties must decode as .jsonSchema, got \(format)")
            return
        }
        XCTAssertEqual(schema.additionalProperties, .bool(false))
        XCTAssertEqual(schema.properties?["x"]?.type, .integer)
    }

    func testFlatSchemaWithEnumPropertyDecodesAsJsonSchema() throws {
        // A flat schema whose property has an enum (unknown to PropertyFormat)
        // must decode as .jsonSchema to preserve the enum constraint.
        let rawJSON = """
        {"type":"object","properties":{"role":{"type":"string","description":"User role","enum":["admin","user"]}},"required":["role"]}
        """
        let data = Data(rawJSON.utf8)
        let format = try JSONDecoder().decode(Ollama.GenerateFormat.self, from: data)
        guard case .jsonSchema(let schema) = format else {
            XCTFail("Schema with enum property must decode as .jsonSchema, got \(format)")
            return
        }
        XCTAssertEqual(schema.properties?["role"]?.enumValues, ["admin", "user"])
    }

    // MARK: - Live schema smoke test (opt-in, requires running local Ollama)

    func testLiveSchemaSmokeWithLocalModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LANGTOOLS_RUN_LIVE_SCHEMA_TESTS"] == "1" else {
            throw XCTSkip("Set LANGTOOLS_RUN_LIVE_SCHEMA_TESTS=1 to run live schema smoke")
        }

        let modelName = (environment["LANGTOOLS_LIVE_SCHEMA_MODEL"] ?? "llama3.2:latest")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty, let model = OllamaModel(rawValue: modelName) else {
            XCTFail("LANGTOOLS_LIVE_SCHEMA_MODEL must be a valid model name")
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let liveAPI = Ollama(configuration: .init(baseURL: URL(string: "http://localhost:11434")!, session: session))

        // Construct a schema with nested arrays, required fields, additionalProperties:false
        let schema = JSONSchema.object(
            properties: [
                "summary": .string(description: "One-line summary"),
                "items": .array(
                    items: .object(
                        properties: [
                            "name": .string(description: "Item name"),
                            "quantity": .integer(description: "Quantity", minimum: 1, maximum: 99),
                            "tags": .array(
                                items: .string(),
                                description: "Optional tags",
                                minItems: 0
                            )
                        ],
                        required: ["name", "quantity"]
                    ),
                    description: "List of items"
                )
            ],
            required: ["summary", "items"],
            additionalProperties: .bool(false)
        )

        // Build request through the factory (exercises responseSchema wiring)
        let genericRequest = try Ollama.chatRequest(
            model: model,
            messages: [Ollama.Message(role: .user, content: "List 2 fruits with name, quantity, and tags. JSON only.")],
            tools: nil,
            responseSchema: schema,
            toolEventHandler: { _ in }
        )
        var chatRequest = try XCTUnwrap(genericRequest as? Ollama.ChatRequest)
        chatRequest.stream = false

        // Verify format is set losslessly
        guard case .jsonSchema(let storedSchema) = chatRequest.format else {
            XCTFail("Format must be .jsonSchema, got \(String(describing: chatRequest.format))")
            return
        }
        XCTAssertEqual(storedSchema, schema, "Schema must survive factory unchanged")

        // Send live request
        let response: Ollama.ChatResponse
        do {
            response = try await liveAPI.perform(request: chatRequest)
        } catch {
            XCTFail("Live chat request failed: \(error)")
            return
        }

        XCTAssertTrue(response.done, "Response should be complete")
        let content = try XCTUnwrap(response.message?.content.text, "Response should have content")
        XCTAssertFalse(content.isEmpty, "Content should not be empty")

        // Validate returned JSON against schema
        guard let contentData = content.data(using: .utf8) else {
            XCTFail("Response content is not valid UTF-8")
            return
        }
        let json: JSON
        do {
            json = try JSON(data: contentData)
        } catch {
            XCTFail("Response is not valid JSON: \(content.prefix(200))")
            return
        }
        do {
            try json.validate(against: schema)
        } catch {
            XCTFail("Response failed schema validation: \(error)\nJSON: \(content.prefix(500))")
            return
        }

        // Verify required fields present
        XCTAssertNotNil(json["summary"]?.stringValue, "summary required")
        let items = try XCTUnwrap(json["items"]?.arrayValue, "items required")
        XCTAssertGreaterThan(items.count, 0, "items should be non-empty")
        for item in items {
            XCTAssertNotNil(item["name"]?.stringValue, "item.name required")
            XCTAssertNotNil(item["quantity"]?.intValue, "item.quantity required")
        }
    }
}
