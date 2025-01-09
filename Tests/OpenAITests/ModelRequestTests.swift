//
//  ModelRequestTests.swift
//  LangTools
//
//  Created by Reid Chatham on 1/8/25.
//

// This file was generated by Claude.
import XCTest
import LangTools
@testable import OpenAI
@testable import TestUtils

final class ModelRequestTests: XCTestCase {
    var api: OpenAI!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = OpenAI(apiKey: "test_key").configure(testURLSessionConfiguration: config)
    }

    override func tearDown() {
        MockURLProtocol.mockNetworkHandlers.removeAll()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - List Models Tests

    func testListModelsRequest() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ListModelDataRequest.endpoint] = { request in
            // Verify request
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test_key")

            return (.success(try self.getData(filename: "list_models_response")!), 200)
        }

        let response = try await api.perform(request: OpenAI.ListModelDataRequest())

        // Verify response
        XCTAssertEqual(response.object, "list")
        XCTAssertEqual(response.data.count, 3)

        // Verify first model
        XCTAssertEqual(response.data[0].id, "gpt-4o")
        XCTAssertEqual(response.data[0].object, "model")
        XCTAssertEqual(response.data[0].created, 1_686_935_002)
        XCTAssertEqual(response.data[0].owned_by, "openai")

        // Verify fine-tuned model
        XCTAssertEqual(response.data[2].id, "ft:gpt-4o-mini:acemeco:suffix:abc123")
        XCTAssertEqual(response.data[2].owned_by, "organization-owner")
    }

    // MARK: - Retrieve Model Tests

    func testRetrieveModelRequest() async throws {
        let modelId = "gpt-4o"
        MockURLProtocol.mockNetworkHandlers[OpenAI.RetrieveModelRequest.endpoint] = { request in
            // Verify request
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test_key")
            XCTAssertTrue(request.url?.absoluteString.hasSuffix(modelId) ?? false)

            return (.success(try self.getData(filename: "retrieve_model_response")!), 200)
        }

        let response = try await api.perform(request: OpenAI.RetrieveModelRequest(model: modelId))

        // Verify response
        XCTAssertEqual(response.id, "gpt-4o")
        XCTAssertEqual(response.object, "model")
        XCTAssertEqual(response.created, 1_686_935_002)
        XCTAssertEqual(response.owned_by, "openai")
    }

    // MARK: - Delete Model Tests

    func testDeleteFineTunedModelRequest() async throws {
        let modelId = "ft:gpt-4o-mini:acemeco:suffix:abc123"
        MockURLProtocol.mockNetworkHandlers[OpenAI.DeleteFineTunedModelRequest.endpoint] = {
            request in
            // Verify request
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test_key")
            XCTAssertTrue(request.url?.absoluteString.hasSuffix(modelId) ?? false)

            return (.success(try self.getData(filename: "delete_model_response")!), 200)
        }

        let response = try await api.perform(
            request: OpenAI.DeleteFineTunedModelRequest(model: modelId))

        // Verify response
        XCTAssertEqual(response.id, modelId)
        XCTAssertEqual(response.object, "model")
        XCTAssertTrue(response.deleted)
    }

    // MARK: - Error Tests

    func testUnauthorizedError() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.ListModelDataRequest.endpoint] = { _ in
            let errorResponse = OpenAIErrorResponse(
                error: .init(
                    message: "Invalid authentication token",
                    type: "authentication_error",
                    param: nil,
                    code: "invalid_api_key"
                ))
            return (.success(try errorResponse.data()), 401)
        }

        do {
            _ = try await api.perform(request: OpenAI.ListModelDataRequest())
            XCTFail("Expected error to be thrown")
        } catch let error as LangToolError {
            if case .responseUnsuccessful(let code, _, let apiError) = error {
                XCTAssertEqual(code, 401)
                if let openAIError = apiError as? OpenAIErrorResponse {
                    XCTAssertEqual(openAIError.error.type, "authentication_error")
                    XCTAssertEqual(openAIError.error.code, "invalid_api_key")
                } else {
                    XCTFail("Expected OpenAIErrorResponse")
                }
            } else {
                XCTFail("Expected responseUnsuccessful error")
            }
        }
    }

    func testModelNotFoundError() async throws {
        MockURLProtocol.mockNetworkHandlers[OpenAI.RetrieveModelRequest.endpoint] = { _ in
            let errorResponse = OpenAIErrorResponse(
                error: .init(
                    message: "The model 'nonexistent-model' does not exist",
                    type: "invalid_request_error",
                    param: "model",
                    code: "model_not_found"
                ))
            return (.success(try errorResponse.data()), 404)
        }

        do {
            _ = try await api.perform(
                request: OpenAI.RetrieveModelRequest(model: "nonexistent-model"))
            XCTFail("Expected error to be thrown")
        } catch let error as LangToolError {
            if case .responseUnsuccessful(let code, _, let apiError) = error {
                XCTAssertEqual(code, 404)
                if let openAIError = apiError as? OpenAIErrorResponse {
                    XCTAssertEqual(openAIError.error.type, "invalid_request_error")
                    XCTAssertEqual(openAIError.error.code, "model_not_found")
                    XCTAssertEqual(openAIError.error.param, "model")
                } else {
                    XCTFail("Expected OpenAIErrorResponse")
                }
            } else {
                XCTFail("Expected responseUnsuccessful error")
            }
        }
    }
}
