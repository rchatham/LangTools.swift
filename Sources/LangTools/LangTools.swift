//
//  LangTools.swift
//  LangTools
//
//  Created by Reid Chatham on 7/17/24.
//

import Foundation

public protocol LangTools {
    associatedtype Model: RawRepresentable
    associatedtype ErrorResponse: Codable & Error
    func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response
    func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error>
    ///  When implementing decodeStream yourself, throw an error when the buffer is incomplete and additional lines of data from the response are needed to decode the buffer. If the buffer can be handled it should at least return nil to indicate that the buffer can be cleared. If a nil response is returned the buffer will be cleared and then it will continue reading the data stream, throwing an error will continue appending the data stream to the current buffer.
    static func decodeStream<T: Decodable>(_ buffer: String) throws -> T?

    static var requestValidators: [(any LangToolsRequest) -> Bool] { get }

    static func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest
    func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]?, toolEventHandler: @escaping (LangToolsToolEvent) -> Void) throws -> any LangToolsChatRequest

    var session: URLSession { get }
    func prepare(request: some LangToolsRequest) throws -> URLRequest
}

extension LangTools {
    public func chatRequest(model: any RawRepresentable, messages: [any LangToolsMessage], tools: [any LangToolsTool]? = nil, toolEventHandler: @escaping (LangToolsToolEvent) -> Void = { _ in }) throws -> any LangToolsChatRequest {
        try Self.chatRequest(model: model, messages: messages, tools: tools, toolEventHandler: toolEventHandler)
    }

    public func canHandleRequest<Request: LangToolsRequest>(_ request: Request) -> Bool {
        Self.requestValidators.reduce(false) { $0 || $1(request) }
    }

    public func perform<Request: LangToolsRequest>(request: Request, completion: @escaping (Result<Request.Response, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        Task {
            if request.stream, let request = request as? any LangToolsStreamableRequest {
                do { for try await response in stream(request: request) { completion(.success(response as! Request.Response)) }; didCompleteStreaming?(nil) } catch { didCompleteStreaming?(error) }}
            else { do { completion(.success(try await perform(request: request))) } catch { completion(.failure(error)) }}
        }
    }

    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        return try await complete(request: request, response: try request.update(response: try await perform(request: try prepare(request: request.updating(stream: false)))) )
    }

    private func perform<Response: Decodable>(request: URLRequest) async -> Result<Response, Error> {
        do { return .success(try await perform(request: request)) } catch { return .failure(error) }
    }

    private func perform<Response: Decodable>(request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw LangToolsError.requestFailed }
        guard httpResponse.statusCode == 200 else { throw LangToolsError.responseUnsuccessful(statusCode: httpResponse.statusCode, Self.decodeError(data: data)) }
        return Response.self == Data.self ? data as! Response : try Self.decodeResponse(data: data)
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        guard request.stream ?? true else { return AsyncThrowingSingleItemStream(value: { try await perform(request: request) }) }

        print("📡 LangTools.stream() - Preparing HTTP request")
        let httpRequest: URLRequest
        do {
            httpRequest = try prepare(request: request.updating(stream: true))
            print("   ✅ HTTP request prepared")
            print("   URL: \(httpRequest.url?.absoluteString ?? "nil")")
        } catch {
            print("   ❌ Failed to prepare request: \(error)")
            return AsyncSingleErrorStream(error: error)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    print("   🌐 Calling session.bytes(for:)...")
                    let (bytes, response) = try await session.bytes(for: httpRequest)
                    print("   ✅ Got response from server")

                    guard let httpResponse = response as? HTTPURLResponse else {
                        print("   ❌ Response is not HTTPURLResponse")
                        return continuation.finish(throwing: LangToolsError.requestFailed)
                    }

                    print("   Status code: \(httpResponse.statusCode)")

                    guard httpResponse.statusCode == 200 else {
                        print("   ❌ Non-200 status code: \(httpResponse.statusCode)")
                        var error: Error?;
                        do { error = try await bytes.lines.reduce("", +).data(using: .utf8).flatMap { Self.decodeError(data: $0) }}
                        catch let _error { error = _error }
                        return continuation.finish(throwing: LangToolsError.responseUnsuccessful(statusCode: httpResponse.statusCode, error))
                    }

                    print("   ✅ Status 200 - Processing stream...")

                    var combinedResponse = Request.Response.empty
                    // buffer used for responses that need multiple lines to decode
                    var errorBuffer: Error?
                    var buffer = ""
                    var lineCount = 0
                    for try await line in bytes.lines {
                        lineCount += 1
                        if lineCount == 1 {
                            print("   📥 Receiving streamed data...")
                        }
                        // ensure line is a complete json object if not concat to previous line and continue
                        buffer += line
                        var response: Request.Response?
                        do {
                            response = try Self.decodeStream(buffer)
                            buffer = ""
                            errorBuffer = nil
                        } catch {
                            // We do not throw the error here because we are using it to prevent erasing the buffer when decoding errors in case the response needs multiple lines to decode. If the buffer can be handled, it should return nil.
                            errorBuffer = error
                            continue
                        }
                        if let response {
                            // If we were able to create a response object we update the decoded response with information from the request and return it before adding it to the combined response used to handle tool completions.
                            let updatedResponse = try request.update(response: response)
                            continuation.yield(updatedResponse)
                            combinedResponse = combinedResponse.combining(with: updatedResponse)
                        }
                    }

                    if let errorBuffer, !buffer.isEmpty {
                        throw LangToolsError.failiedToDecodeStream(buffer: buffer, error: errorBuffer)
                    }

                    print("   📊 Processed \(lineCount) lines from stream")

                    if let completionRequest = try await completionRequest(request: request, response: combinedResponse) {
                        print("   🔄 Tool calling - making completion request...")
                        for try await response in stream(request: completionRequest) {
                            continuation.yield(try request.update(response: response))
                        }
                    }

                    print("   ✅ Stream completed successfully")
                    continuation.finish()
                } catch {
                    print("   ❌ Stream error: \(error)")
                    print("   Error type: \(type(of: error))")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // Used because simply mapping the value will cause a compiler error in certain situations, such as in the non-async perform method.
    private func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<any LangToolsStreamableResponse, Error> {
        return AsyncThrowingStream { cont in Task { for try await response in stream(request: request) { cont.yield(response) }; cont.finish() } }
    }

    private func complete<Request: LangToolsRequest>(request: Request, response: Request.Response) async throws -> Request.Response {
        return try await completionRequest(request: request, response: response).flatMap { try await perform(request: $0) } ?? response
    }

    private func completionRequest<Request: LangToolsRequest>(request: Request, response: Request.Response) async throws -> Request? {
        guard let response = response as? any LangToolsToolCallingResponse else { return nil }
        return try await (request as? any LangToolsToolCallingRequest)?.completion(self, response: response) as? Request
    }

    public static func decodeStream<T: Decodable>(_ buffer: String) throws -> T? {
        return if buffer.hasPrefix("data:") && !buffer.contains("[DONE]"), let data = buffer.dropFirst(5).data(using: .utf8) { try Self.decodeResponse(data: data) } else { nil }
    }
}


public enum LangToolsError: Error {
    case invalidData, streamParsingFailure, invalidURL, requestFailed, invalidContentType
    case invalidArgument(String)
    case jsonParsingFailure(Error)
    case responseUnsuccessful(statusCode: Int, Error?)
    case apiError(Codable & Error)
    case failiedToDecodeStream(buffer: String, error: Error)
}

// MARK: - Helpers

public extension LangTools {
    static func decode<Response: Decodable>(completion: @escaping (Result<Response, Error>) -> Void) -> (Data) -> Void { return { completion(decode(data: $0)) }}
    static func decode<Response: Decodable>(data: Data) -> Result<Response, Error> { let d = JSONDecoder(); do { return .success(try decodeResponse(data: data, decoder: d)) } catch { return .failure(error) }}
    static func decodeResponse<Response: Decodable>(data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> Response { do { return try decoder.decode(Response.self, from: data) } catch { throw decodeError(data: data, decoder: decoder) ?? LangToolsError.jsonParsingFailure(error) }}
    static func decodeError(data: Data, decoder: JSONDecoder = JSONDecoder()) -> ErrorResponse? { return (try? decoder.decode(ErrorResponse.self, from: data)) }
}

func AsyncThrowingSingleItemStream<T>(value: @escaping () async throws -> T) -> AsyncThrowingStream<T, Error> {
    return AsyncThrowingStream { cont in Task { do { cont.yield(try await value()) } catch { cont.finish(throwing: error) }; cont.finish() }}
}
func AsyncSingleErrorStream<T>(error: Error) -> AsyncThrowingStream<T, Error> {
    return AsyncThrowingStream { $0.finish(throwing: error) }
}
func AsyncSingleErrorStream<T>(error: @escaping () async throws -> Error) -> AsyncThrowingStream<T, Error> {
    return AsyncThrowingStream { cont in Task { cont.finish(throwing: try await error()) } }
}

// MARK: - Utilities

extension String {
    public var stringDictionary: [String:String]? { return data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? [String:String] }}
    public var dictionary: [String:JSON]? { return data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? [String:JSON] }}
    public var json: JSON? { return try? JSON(self) }
}

extension Dictionary where Key == String, Value == String {
    public var string: String? { (try? JSONSerialization.data(withJSONObject: self, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) }}
}

extension Optional where Wrapped: LangToolsRequest {
    func flatMap<U>(_ a: (Wrapped) async throws -> U?) async throws -> U? { switch self { case .some(let wrapped): return try await a(wrapped); case .none: return nil }}
}

public extension AsyncThrowingStream {
    func mapAsyncThrowingStream<T>(_ map: @escaping (Element) -> T) -> AsyncThrowingStream<T, Error> {
        var iterator = self.makeAsyncIterator()
        return AsyncThrowingStream<T, Error>(unfolding: { try await iterator.next().flatMap { map($0) } })
    }

    func compactMapAsyncThrowingStream<T>(_ compactMap: @escaping (Element) -> T?) -> AsyncThrowingStream<T, Error> {
        return AsyncThrowingStream<T, Error> { continuation in Task { do {
            for try await value in self { if let mapped = compactMap(value) { continuation.yield(mapped) } }
        } catch { continuation.finish(throwing: error) }
            continuation.finish()
        } }
    }
}

@propertyWrapper
public struct CodableIgnored<T>: Codable {
    public var wrappedValue: T?
    public init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws { self.wrappedValue = nil }
    public func encode(to encoder: Encoder) throws {} // Do nothing
}

extension KeyedDecodingContainer {
    public func decode<T>(_ type: CodableIgnored<T>.Type, forKey key: Self.Key) throws -> CodableIgnored<T> { return CodableIgnored(wrappedValue: nil) }
}

extension KeyedEncodingContainer {
    public mutating func encode<T>(_ value: CodableIgnored<T>, forKey key: KeyedEncodingContainer<K>.Key) throws {} // Do nothing
}
