import Foundation

// Type erased async route handler. Returning `BridgeHTTPResponse` (rather than throwing)
// keeps error mapping in one place inside each handler — every error becomes an
// `error` envelope with a stable code the MCP server can branch on.
typealias BridgeRouteHandler = (BridgeHTTPRequest) async -> BridgeHTTPResponse

// Routes incoming requests to the right handler based on method + path template.
// Matching is intentionally simple — string equality on method and a regex-free path
// template like `/v1/notes/:id/segments`. Path parameters are returned in
// `request.query` under their template name so handlers don't need a separate API.
struct BridgeRouter {
    // One registered route. Order matters — first match wins, so concrete paths must
    // be registered before parameterised ones.
    private struct Route {
        let method: String
        let template: [PathSegment]
        let handler: BridgeRouteHandler
    }

    // Path segment type; either a literal token to match exactly or a parameter name
    // to capture into `request.query`.
    private enum PathSegment: Equatable {
        case literal(String)
        case parameter(String)
    }

    private var routes: [Route] = []

    // Registers a handler. `template` uses `:name` for path parameters, e.g.
    // `/v1/notes/:id/segments`. The handler receives the request with the
    // parameter values merged into `request.query`.
    mutating func add(method: String, template: String, handler: @escaping BridgeRouteHandler) {
        let segments = parseTemplate(template)
        routes.append(Route(method: method.uppercased(), template: segments, handler: handler))
    }

    // Dispatches a request, returning either the handler's response or a 404/405 envelope.
    func dispatch(_ request: BridgeHTTPRequest) async -> BridgeHTTPResponse {
        let pathSegments = request.path.split(separator: "/").map(String.init)
        var pathMatched = false
        for route in routes where route.template.count == pathSegments.count {
            guard let captured = match(template: route.template, against: pathSegments) else {
                continue
            }

            pathMatched = true
            if route.method != request.method.uppercased() { continue }

            var enriched = request
            for (key, value) in captured {
                enriched.query[key] = value
            }
            return await route.handler(enriched)
        }

        if pathMatched {
            return .error(status: 405, code: "method_not_allowed", message: "method \(request.method) not allowed for \(request.path)")
        }
        return .error(status: 404, code: "not_found", message: "no route for \(request.path)")
    }

    // Returns captured parameters when the template matches, or nil when it doesn't.
    private func match(template: [PathSegment], against segments: [String]) -> [String: String]? {
        var captured: [String: String] = [:]
        for (templateSegment, pathSegment) in zip(template, segments) {
            switch templateSegment {
            case .literal(let value):
                if value != pathSegment { return nil }
            case .parameter(let name):
                captured[name] = pathSegment.removingPercentEncoding ?? pathSegment
            }
        }
        return captured
    }

    // Splits a template string into typed segments. Empty segments (leading slash)
    // are dropped to match the way `request.path.split(separator: "/")` produces them.
    private func parseTemplate(_ template: String) -> [PathSegment] {
        template.split(separator: "/").map { piece -> PathSegment in
            if piece.first == ":" {
                return .parameter(String(piece.dropFirst()))
            }
            return .literal(String(piece))
        }
    }
}
