//
//  LangTools.swift
//  LangTools
//
//  Created by Reid Chatham on 7/17/24.
//

import Foundation

public protocol LangTools {
    associatedtype ErrorResponse: Codable & Error
    func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response
    func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error>
    var requestTypes: [(any LangToolsRequest) -> Bool] { get }

    var session: URLSession { get }
    var streamManager: StreamSessionManager<Self> { get }
    func prepare(request: some LangToolsRequest) throws -> URLRequest
    static func processStream(data: Data, completion: @escaping (Data) -> Void)
}

extension LangTools {
    public func canHandleRequest<Request: LangToolsRequest>(_ request: Request) -> Bool {
        return requestTypes.reduce(false) { $0 || $1(request) }
    }

    public func perform<Request: LangToolsRequest>(request: Request, completion: @escaping (Result<Request.Response, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        Task {
            if request.stream, let request = request as? any LangToolsStreamableRequest {
                do { for try await response in stream(request: request) { completion(.success(response as! Request.Response)) }; didCompleteStreaming?(nil) } catch { didCompleteStreaming?(error) }}
            else { do { completion(.success(try await perform(request: request))) } catch { completion(.failure(error)) }}
        }
    }

    // In order to call the function completion in non-streaming calls, we are
    // unable to return the intermediate call and thus you can not mix responding 
    // to functions in your code AND using function closures. If this functionality 
    // is needed use streaming. This functionality may be able to be added via a 
    // configuration callback on the function or request in the future.
    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        return try await complete(request: request, response: try request.update(response: try await perform(request: try prepare(request: request.updating(stream: false)))) )
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        guard request.stream ?? true else { return AsyncThrowingSingleItemStream(value: { try await perform(request: request) }) }
        let httpRequest: URLRequest; do { httpRequest = try prepare(request: request.updating(stream: true)) } catch { return AsyncThrowingStream { $0.finish(throwing: error) }}
        return streamManager.stream(task: session.dataTask(with: httpRequest), updateResponse: { try request.update(response: $0) }) { try complete(request: request, response: $0) }
    }

    // Used because simply mapping the value will cause a copiler error in certain situations, such as in the non-async perform method.
    public func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<any LangToolsStreamableResponse, Error> {
        return stream(request: request).mapAsyncThrowingStream { $0 }
    }

    private func perform<Response: Decodable>(request: URLRequest) async -> Result<Response, Error> {
        do { return .success(try await perform(request: request)) } catch { return .failure(error) }
    }

    private func perform<Response: Decodable>(request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw LangToolError.requestFailed(nil) }
        guard httpResponse.statusCode == 200 else { throw LangToolError.responseUnsuccessful(statusCode: httpResponse.statusCode, status: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode), Self.decodeError(data: data)) }
        return Response.self == Data.self ? data as! Response : try Self.decodeResponse(data: data)
    }

    private func complete<Request: LangToolsRequest>(request: Request, response: Request.Response) async throws -> Request.Response {
        return try await completionRequest(request: request, response: response).flatMap { try await perform(request: $0) } ?? response
    }

    private func complete<Request: LangToolsStreamableRequest>(request: Request, response: Request.Response) throws -> URLSessionDataTask? {
        return try completionRequest(request: request, response: response).flatMap { session.dataTask(with: try prepare(request: $0)) }
    }

    private func completionRequest<Request: LangToolsRequest>(request: Request, response: Request.Response) throws -> Request? {
        return try (response as? any LangToolsToolCallingResponse).flatMap { try (request as? any LangToolsToolCallingRequest & LangToolsCompletableRequest)?.completion(response: $0) } as? Request
    }
}

public class StreamSessionManager<LangTool: LangTools>: NSObject, URLSessionDataDelegate {
    private var task: URLSessionDataTask? = nil
    private var didReceiveEvent: ((Data) -> Void)? = nil
    private var didCompleteStream: ((Error?) -> Void)? = nil
    private var completion: (([Data]) throws -> URLSessionDataTask?)? = nil
    private var data: [Data] = []

    func stream<Response: LangToolsStreamableResponse>(task: URLSessionDataTask, updateResponse: @escaping (Response) throws -> Response, completion: @escaping (Response) throws -> URLSessionDataTask?) -> AsyncThrowingStream<Response, Error> {
        self.completion = { try completion(try updateResponse(try StreamSessionManager.response(from: $0))) }
        return AsyncThrowingStream { continuation in
            didReceiveEvent = {
                do { continuation.yield(try updateResponse(try LangTool.decodeResponse(data: $0))) }
                catch { continuation.finish(throwing: error) }
            }
            didCompleteStream = { continuation.finish(throwing: $0) }
            continuation.onTermination = { @Sendable _ in (self.task, self.didReceiveEvent, self.didCompleteStream, self.completion, self.data) = (nil, nil, nil, nil, []) }
            self.task = task; task.resume()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let error = LangTool.decodeError(data: data) { return didCompleteStream?(error) ?? () }
        LangTool.processStream(data: data) { [weak self] data in
            self?.data.append(data)
            self?.didReceiveEvent?(data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var error = error; if error == nil { do {
            if !data.isEmpty, let task = try completion?(data) {
                data = []; self.task = task; task.resume(); return /* if new task is returned do not call didCompleteStream */
            }
        } catch let err { error = err } }
        didCompleteStream?(error)
    }

    private static func response<Response: LangToolsStreamableResponse>(from data: [Data]) throws -> Response {
        return try data.compactMap { try LangTool.decodeResponse(data: $0) }.reduce(Response.empty) { $0.combining(with: $1) }
    }
}


public enum LangToolError: Error {
    case invalidData, streamParsingFailure, invalidURL
    case requestFailed(Error?)
    case jsonParsingFailure(Error)
    case responseUnsuccessful(statusCode: Int, status: String, Error?)
    case apiError(Codable & Error)
}

// MARK: - Helpers

public extension LangTools {
    static func decode<Response: Decodable>(completion: @escaping (Result<Response, Error>) -> Void) -> (Data) -> Void { return { completion(decode(data: $0)) }}
    static func decode<Response: Decodable>(data: Data) -> Result<Response, Error> { let d = JSONDecoder(); do { return .success(try decodeResponse(data: data, decoder: d)) } catch { return .failure(error as! LangToolError) }}
    static func decodeResponse<Response: Decodable>(data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> Response { do { return try decoder.decode(Response.self, from: data) } catch { throw decodeError(data: data, decoder: decoder) ?? .jsonParsingFailure(error) }}
    static func decodeError(data: Data, decoder: JSONDecoder = JSONDecoder()) -> LangToolError? { return (try? decoder.decode(ErrorResponse.self, from: data)).flatMap { .apiError($0) }}
}

// MARK: - Utilities

extension String {
    public var dictionary: [String:String]? { return data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? [String:String] }}
}

extension Dictionary where Key == String, Value == String {
    public var string: String? { (try? JSONSerialization.data(withJSONObject: self, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) }}
}

extension Optional where Wrapped: LangToolsRequest {
    func flatMap<U>(_ a: (Wrapped) async throws -> U?) async throws -> U? { switch self { case .some(let wrapped): return try await a(wrapped); case .none: return nil }}
}

func AsyncThrowingSingleItemStream<U>(value: @escaping () async throws -> U) -> AsyncThrowingStream<U, Error> {
    return AsyncThrowingStream { cont in Task { do { cont.yield(try await value()) } catch { cont.finish(throwing: error) }; cont.finish() }}
}

extension AsyncThrowingStream {
    func mapAsyncThrowingStream<T>(_ map: @escaping (Element) -> T) -> AsyncThrowingStream<T, Error> {
        var iterator = self.makeAsyncIterator()
        return AsyncThrowingStream<T, Error>(unfolding: { try await iterator.next().flatMap { map($0) } })
    }
}
