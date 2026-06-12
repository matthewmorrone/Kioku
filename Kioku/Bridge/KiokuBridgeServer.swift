import Combine
import Foundation
import Network
import os

// Hosts a localhost/LAN HTTP listener for the MCP bridge.
//
// The bridge is intentionally minimal: NWListener over TCP, plain HTTP/1.1 with
// CRLF framing, bearer-token auth on every request. It runs only while the user
// has flipped the toggle in Settings — start() and stop() are idempotent so the
// SwiftUI binding can drive it directly.
//
// All NotesStore mutations are dispatched onto MainActor so the existing single-
// writer guarantee (and didSet-driven persistence) keeps holding.
@MainActor
final class KiokuBridgeServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    // A real MCP client opens one socket per call; these bounds only matter to
    // misbehaving or hostile LAN peers. Lifetime (not idle) timeout keeps the
    // bookkeeping to one task per connection — every accepted socket is closed
    // after the response anyway (Connection: close).
    static let maxConcurrentConnections = 16
    static let connectionLifetimeSeconds: UInt64 = 15

    private let logger = Logger(subsystem: "com.kioku.bridge", category: "server")
    private var routes: BridgeRouter = BridgeRouter()
    private var notesStore: NotesStore?
    private var listener: NWListener?
    private var queue = DispatchQueue(label: "com.kioku.bridge.listener")
    private var connections: Set<ObjectIdentifier> = []
    private var connectionsByID: [ObjectIdentifier: NWConnection] = [:]
    private var lifetimeTasksByID: [ObjectIdentifier: Task<Void, Never>] = [:]

    // Constructs an unattached bridge server. attach(notesStore:) must be called
    // before start() — SwiftUI @StateObject initializers can't see each other so
    // wiring happens in ContentView.onAppear instead.
    init() {}

    // Wires the live notes store and registers the routes. Idempotent on the
    // same store reference; calling with a different store replaces the routes.
    func attach(notesStore: NotesStore) {
        self.notesStore = notesStore
        var router = BridgeRouter()
        BridgeRoutes.register(into: &router, notesStore: notesStore)
        self.routes = router
    }

    // Starts the listener with the current settings. No-op when already running.
    // Errors surface through `state` so the SwiftUI section can show them.
    func start() {
        switch state {
        case .running, .starting:
            return
        case .stopped, .failed:
            break
        }

        guard notesStore != nil else {
            state = .failed("notes store not attached")
            return
        }

        state = .starting
        let portValue = BridgeSettings.currentPort()
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            state = .failed("invalid port \(portValue)")
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            let newListener = try NWListener(using: parameters, on: port)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in self.handleListenerState(state, port: portValue) }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { @MainActor in self.accept(connection) }
            }
            newListener.start(queue: queue)
            self.listener = newListener
        } catch {
            state = .failed("listener init failed: \(error.localizedDescription)")
            logger.error("listener init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Stops the listener and tears down any open connections. Safe to call from any state.
    func stop() {
        listener?.cancel()
        listener = nil
        for (_, connection) in connectionsByID {
            connection.cancel()
        }
        for (_, task) in lifetimeTasksByID {
            task.cancel()
        }
        connections.removeAll()
        connectionsByID.removeAll()
        lifetimeTasksByID.removeAll()
        state = .stopped
    }

    // Reflects NWListener state changes into the published `state` so Settings UI updates.
    private func handleListenerState(_ listenerState: NWListener.State, port: Int) {
        switch listenerState {
        case .ready:
            state = .running(port: port)
            logger.info("bridge listening on \(port, privacy: .public)")
        case .failed(let error):
            state = .failed(error.localizedDescription)
            logger.error("listener failed: \(error.localizedDescription, privacy: .public)")
        case .cancelled:
            state = .stopped
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    // Begins reading from one accepted connection. The connection drives itself
    // through receive callbacks until the parser yields a complete request.
    // Sockets past the concurrency cap are refused outright, and every accepted
    // socket gets a hard lifetime deadline so a peer that trickles bytes (or
    // never finishes a body) cannot hold buffers open indefinitely.
    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConcurrentConnections else {
            logger.warning("connection refused: too many concurrent connections")
            connection.cancel()
            return
        }

        let id = ObjectIdentifier(connection)
        connections.insert(id)
        connectionsByID[id] = connection
        lifetimeTasksByID[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectionLifetimeSeconds * 1_000_000_000)
            guard Task.isCancelled == false else { return }
            self?.logger.warning("connection closed: lifetime deadline reached")
            self?.connectionsByID[id]?.cancel()
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self.removeConnection(id: id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(on: connection, buffer: Data())
    }

    // Drains bytes from the connection until one HTTP request has been parsed,
    // dispatches it, writes the response, then closes the connection. The bridge
    // does not need keep-alive — the MCP server opens a fresh socket per call.
    // The Network callback arrives on the listener queue; it immediately hops to
    // MainActor where all connection bookkeeping and parsing live.
    private func receiveLoop(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            let received = data
            Task { @MainActor [weak self] in
                self?.processReceived(received, isComplete: isComplete, error: error, on: connection, buffer: buffer)
            }
        }
    }

    // Handles one receive-callback's worth of bytes on MainActor: accumulate,
    // authenticate as soon as headers are complete, parse, dispatch, respond.
    private func processReceived(
        _ data: Data?,
        isComplete: Bool,
        error: NWError?,
        on connection: NWConnection,
        buffer: Data
    ) {
        if let error {
            logger.error("receive failed: \(error.localizedDescription, privacy: .public)")
            connection.cancel()
            return
        }

        var combined = buffer
        if let data, data.isEmpty == false {
            combined.append(data)
        }

        // Reject unauthenticated requests the moment the header block is readable —
        // before any body bytes are buffered on an attacker's behalf.
        if let headers = BridgeHTTPParser.headerFields(combined),
           isAuthorized(headerValue: headers["authorization"]) == false {
            write(.error(status: 401, code: "unauthorized", message: "missing or invalid bearer token"), on: connection) {
                connection.cancel()
            }
            return
        }

        // Try to parse a request from what we have so far.
        let parsed: (request: BridgeHTTPRequest, remaining: Data)?
        do {
            parsed = try BridgeHTTPParser.parse(combined)
        } catch {
            logger.error("parse failed: \(String(describing: error), privacy: .public)")
            write(.error(status: 400, code: "bad_request", message: "malformed http request"), on: connection) {
                connection.cancel()
            }
            return
        }

        if let parsed {
            Task { @MainActor in
                let response = await self.handle(parsed.request)
                self.write(response, on: connection) { connection.cancel() }
            }
            return
        }

        if isComplete {
            connection.cancel()
            return
        }

        receiveLoop(on: connection, buffer: combined)
    }

    // Compares a presented Authorization header against the provisioned token.
    private func isAuthorized(headerValue: String?) -> Bool {
        guard let headerValue else { return false }
        return headerValue == "Bearer \(BridgeSettings.currentOrProvisionedToken())"
    }

    // Authenticates and dispatches one parsed request. Auth failure short-circuits
    // before any handler runs so handlers don't need to repeat the check.
    private func handle(_ request: BridgeHTTPRequest) async -> BridgeHTTPResponse {
        guard isAuthorized(headerValue: request.header("authorization")) else {
            return .error(status: 401, code: "unauthorized", message: "missing or invalid bearer token")
        }
        return await routes.dispatch(request)
    }

    // Serializes a response onto the wire and runs `then` once the bytes are flushed
    // (or immediately on send error so we don't leak connections on a half-broken socket).
    // `then` hops back to MainActor because the send completion fires on the listener queue.
    private func write(_ response: BridgeHTTPResponse, on connection: NWConnection, then: @escaping @Sendable @MainActor () -> Void) {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(for: response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var packet = Data(head.utf8)
        packet.append(response.body)

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.logger.error("send failed: \(error.localizedDescription, privacy: .public)")
                }
                then()
            }
        })
    }

    // Removes one tracked connection. Called from cancelled/failed state callbacks.
    private func removeConnection(id: ObjectIdentifier) {
        connections.remove(id)
        connectionsByID.removeValue(forKey: id)
        lifetimeTasksByID.removeValue(forKey: id)?.cancel()
    }

    // Maps HTTP status codes used by the bridge to canonical reason phrases.
    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
