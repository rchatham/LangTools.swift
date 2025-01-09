//
//  EmbeddingsTests.swift
//  LangTools
//
//  Created by Reid Chatham on 1/8/25.
//

import XCTest
@testable import TestUtils
@testable import OpenAI

final class EmbeddingsResponseTests: XCTestCase {
    func testEmbeddingsResponseDecodable() throws {
        OpenAI.decode { (result: Result<OpenAI.EmbeddingsResponse, Error>) in
            switch result {
            case .success(let response):
                XCTAssert(
                    response.object == "list" &&
                    response.model == "text-embedding-ada-002" &&
                    response.usage.prompt_tokens == 8 &&
                    response.usage.total_tokens == 8 &&
                    response.data[0].object == "embedding" &&
                    response.data[0].index == 0 &&
                    response.data[0].embedding.count == 1536
                )
            case .failure(let error):
                XCTFail("failed to decode data \(error.localizedDescription)")
            }
        }(try getData(filename: "embeddings_response")!)
    }
}
