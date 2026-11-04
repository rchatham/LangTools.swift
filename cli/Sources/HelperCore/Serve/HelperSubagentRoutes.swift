import Foundation
import AgentDeploy
import HelperLink

/// The helper's subagent routes: the app lists subagents, starts a run with a task,
/// then polls its status. The runs happen on langtools-agent workers through
/// `SubagentService`, which the sandboxed app can't do itself because it can't run
/// `docker` or `ssh`.
enum HelperSubagentRoutes {
    static let paths: [String: String] = [
        HelperSubagentRoute.list: "GET",
        HelperSubagentRoute.run: "POST",
        HelperSubagentRoute.status: "POST",
    ]

    /// The status and JSON body for a subagent request, or nil if `path` isn't one.
    static func respond(path: String, body: Data, service: SubagentService?) async -> (status: HTTPStatus, body: String)? {
        guard paths[path] != nil else { return nil }
        guard let service else {
            return (.notFound, errorBody("Subagents aren't enabled in this helper."))
        }
        do {
            switch path {
            case HelperSubagentRoute.list:
                return (.ok, try json(service.list()))
            case HelperSubagentRoute.run:
                let request = try JSONDecoder().decode(HelperSubagentRunRequest.self, from: body)
                return (.ok, try json(try await service.start(request)))
            default:
                let request = try JSONDecoder().decode(HelperSubagentStatusRequest.self, from: body)
                return (.ok, try json(try await service.status(request)))
            }
        } catch let error as DeployError {
            switch error {
            case .invalidArgument, .workerNotFound: return (.badRequest, errorBody(error.localizedDescription))
            default: return (.internalServerError, errorBody(error.localizedDescription))
            }
        } catch is DecodingError {
            return (.badRequest, errorBody("Invalid subagent request."))
        } catch {
            return (.internalServerError, errorBody(error.localizedDescription))
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try HTTPResponseEncoder.makeJSONEncoder().encode(value), as: UTF8.self)
    }

    private static func errorBody(_ message: String) -> String {
        (try? json(HelperErrorResponse(error: message))) ?? #"{"error":"Unknown error."}"#
    }
}
