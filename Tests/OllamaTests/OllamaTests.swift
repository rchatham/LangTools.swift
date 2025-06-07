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
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }


    func testGenerate() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.GenerateRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.GenerateRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.GenerateRequest.endpoint] = { request in
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

        MockURLProtocol.mockNetworkHandlers[Ollama.GenerateRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.ListModelsRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.ListModelsRequest.endpoint] = { _ in
            return (.success(try self.getData(filename: "error")!), 404)
        }

        do {
            _ = try await api.listModels()
            XCTFail("Expected error to be thrown")
        } catch let error as LangToolError {
            if case .responseUnsuccessful(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 404)
            } else {
                XCTFail("Unexpected error type")
            }
        }
    }

    func testListRunningModels() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.ListRunningModelsRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.ShowModelRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.DeleteModelRequest.endpoint] = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (.success(try self.getData(filename: "success_response")!), 200)
        }

        let response = try await api.deleteModel("mistral:latest")
        XCTAssertEqual(response.status, "success")
    }

    func testCopyModel() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.CopyModelRequest.endpoint] = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "success_response")!), 200)
        }

        let response = try await api.copyModel(source: "llama2", destination: "llama2-backup")
        XCTAssertEqual(response.status, "success")
    }


    func testPullModel() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.PullModelRequest.endpoint] = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "pull_model_response")!), 200)
        }

        let response = try await api.pullModel("llama2")
        XCTAssertEqual(response.status, "downloading model")
        XCTAssertEqual(response.total, 5137025024)
        XCTAssertEqual(response.completed, 2568512512)
    }

    func testStreamPullModel() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.PullModelRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.PushModelRequest.endpoint] = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "push_model_response")!), 200)
        }

        let response = try await api.pushModel("namespace/llama2:latest")
        XCTAssertEqual(response.status, "pushing model")
        XCTAssertEqual(response.total, 1928429856)
    }

    func testStreamPushModel() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.PushModelRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.CreateModelRequest.endpoint] = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (.success(try self.getData(filename: "success_response")!), 200)
        }

        let response = try await api.createModel(model: "custom-model", modelfile: "FROM llama2\nSYSTEM You are a helpful assistant.")
        XCTAssertEqual(response.status, "success")
    }

    func testChat() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.ChatRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.ChatRequest.endpoint] = { request in
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
        MockURLProtocol.mockNetworkHandlers[Ollama.ChatRequest.endpoint] = { request in
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

    func testVersion() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.VersionRequest.endpoint] = { request in
            // Verify request
            XCTAssertEqual(request.httpMethod, "GET")
            return (.success(try self.getData(filename: "version_response-ollama")!), 200)
        }

        let response = try await api.version()
        XCTAssertEqual(response.version, "0.5.1")
    }

    func testVersionError() async throws {
        MockURLProtocol.mockNetworkHandlers[Ollama.VersionRequest.endpoint] = { _ in
            return (.success(try self.getData(filename: "error")!), 404)
        }

        do {
            _ = try await api.version()
            XCTFail("Expected error to be thrown")
        } catch let error as LangToolError {
            if case .responseUnsuccessful(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 404)
            } else {
                XCTFail("Unexpected error type")
            }
        }
    }
}
