//
//  LangTools.swift
//  LangTools
//
//  Created by Reid Chatham on 7/17/24.
//

import Foundation

public protocol LangTools {
    associatedtype ErrorResponse: Codable & Error
    static var url: URL { get }
    var session: URLSession { get }
    var streamManager: StreamSessionManager<Self> { get }
    func prepare(request: some LangToolsRequest) throws -> URLRequest
    func completionRequest<Request: LangToolsRequest>(request: Request, response: Request.Response) throws -> Request?
    static func processStream(data: Data, completion: @escaping (Data) -> Void)
    var requestTypes: [(any LangToolsRequest) -> Bool] { get }
}

extension LangTools {

    public func canHandleRequest<Request: LangToolsRequest>(_ request: Request) -> Bool {
        for requestType in self.requestTypes {
            if requestType(request) { return true }
        }
        return false
    }

    // In order to call the function completion in non-streaming calls, we are
    // unable to return the intermediate call and thus you can not mix responding 
    // to functions in your code AND using function closures. If this functionality 
    // is needed use streaming. This functionality may be able to be added via a 
    // configuration callback on the function or request in the future.
    public func perform<Request: LangToolsRequest>(request: Request) async throws -> Request.Response {
        return try await complete(request: request, response: try await perform(request: try prepare(request: request.updating(stream: false))))
    }

    public func stream<Request: LangToolsStreamableRequest>(request: Request) -> AsyncThrowingStream<Request.Response, Error> {
        guard request.stream else { return AsyncThrowingStream { cont in Task { cont.yield(try await perform(request: request)); cont.finish() }} }
        let httpRequest: URLRequest; do { httpRequest = try prepare(request: request) } catch { return AsyncThrowingStream { $0.finish(throwing: error) }}
        return streamManager.stream(task: session.dataTask(with: httpRequest)) { try complete(request: request, response: $0) }
    }

    private func perform<Response: Decodable>(request: URLRequest) async -> Result<Response, Error> {
        do { return .success(try await perform(request: request)) } catch { return .failure(error) }
    }

    private func perform<Response: Decodable>(request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw LangToolError<ErrorResponse>.requestFailed(nil) }
        guard httpResponse.statusCode == 200 else { throw LangToolError<ErrorResponse>.responseUnsuccessful(statusCode: httpResponse.statusCode, Self.decodeError(data: data)) }
        return Response.self == Data.self ? data as! Response : try Self.decodeResponse(data: data)
    }

    private func complete<Request: LangToolsRequest>(request: Request, response: Request.Response) async throws -> Request.Response {
        return try await completionRequest(request: request, response: response).flatMap { try await perform(request: $0) } ?? response
    }

    private func complete<Request: LangToolsStreamableRequest>(request: Request, response: Request.Response) throws -> URLSessionDataTask? {
        return try completionRequest(request: request, response: response).flatMap { session.dataTask(with: try prepare(request: $0)) }
    }
}

public class StreamSessionManager<LangTool: LangTools>: NSObject, URLSessionDataDelegate {
    private var task: URLSessionDataTask? = nil
    private var didReceiveEvent: ((Data) -> Void)? = nil
    private var didCompleteStream: ((Error?) -> Void)? = nil
    private var completion: (([Data]) throws -> URLSessionDataTask?)? = nil
    private var data: [Data] = []

    func stream<StreamResponse: LangToolsStreamableResponse, Response: Decodable>(task: URLSessionDataTask, completion: @escaping (StreamResponse) throws -> URLSessionDataTask?) -> AsyncThrowingStream<Response, Error> {
        self.completion = { return try completion(try StreamSessionManager.response(from: $0)) }
        return AsyncThrowingStream { continuation in
            didReceiveEvent = { continuation.yield(with: LangTool.decode(data: $0)) }
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


public enum LangToolError<ErrorResponse: Codable & Error>: Error {
    case invalidData, streamParsingFailure, invalidURL
    case requestFailed(Error?)
    case jsonParsingFailure(Error)
    case responseUnsuccessful(statusCode: Int, Error?)
    case apiError(ErrorResponse)
}

// Helpers
public extension LangTools {
    static func decode<Response: Decodable>(completion: @escaping (Result<Response, Error>) -> Void) -> (Data) -> Void { return { completion(decode(data: $0)) }}
    static func decode<Response: Decodable>(data: Data) -> Result<Response, Error> { let d = JSONDecoder(); do { return .success(try decodeResponse(data: data, decoder: d)) } catch { return .failure(error as! LangToolError<ErrorResponse>) }}
    static func decodeResponse<Response: Decodable>(data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> Response { do { return try decoder.decode(Response.self, from: data) } catch { throw decodeError(data: data, decoder: decoder) ?? .jsonParsingFailure(error) }}
    static func decodeError(data: Data, decoder: JSONDecoder = JSONDecoder()) -> LangToolError<ErrorResponse>? { return (try? decoder.decode(ErrorResponse.self, from: data)).flatMap { .apiError($0) }}
}

extension String {
    public var dictionary: [String:String]? { return data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? [String:String] }}
}

extension Optional { func flatMap<U>(_ a: (Wrapped) async throws -> U?) async throws -> U? { switch self { case .some(let wrapped): return try await a(wrapped); case .none: return nil }}}

