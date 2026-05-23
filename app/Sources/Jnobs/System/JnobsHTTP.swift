import Foundation
import Network
import os

/// Minimal HTTP server bound to 127.0.0.1:49152, designed to be consumed by
/// the Jnobs Stream Deck plugin (and any other local control surface).
///
/// We deliberately don't pull in Vapor / Hummingbird / NIO — the surface area
/// is a handful of routes returning JSON, and a Network.framework listener +
/// a 50-line HTTP request parser is enough. Localhost-only, no auth.
///
/// Routes:
///   GET  /state                    → { activeProfile, profiles: [...] }
///   POST /profile/load   {name}    → loads named profile
///   POST /profile/next             → cycle to next profile
///   POST /profile/previous         → cycle to previous profile
///   POST /button/<index>           → fire button N (short-tap action)
///   POST /mute/mic     {value?}    → set or toggle mic mute
///   POST /mute/system  {value?}    → set or toggle system mute
@MainActor
final class JnobsHTTP {
    static let shared = JnobsHTTP()

    private let log = Logger(subsystem: "net.jfound.jnobs", category: "HTTP")
    private let port: NWEndpoint.Port = 49152
    private var listener: NWListener?
    weak var delegate: JnobsHTTPDelegate?

    /// Push a state-changed event to any open SSE listeners.
    private var sseClients: [SSEClient] = []

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Localhost-only: bind to the loopback address explicitly.
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: port)
            // NWListener invokes these on the queue we hand to .start() — `.main`,
            // which IS the main actor — but Swift's strict-concurrency model
            // can't prove that. Assume isolation explicitly.
            listener.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.handle(connection: conn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        self?.log.info("HTTP listening on 127.0.0.1:49152")
                        DiagSink.shared.info("HTTP", "listening on 127.0.0.1:49152")
                    case .failed(let err):
                        self?.log.error("listener failed: \(err.localizedDescription, privacy: .public)")
                        DiagSink.shared.error("HTTP", "listener failed: \(err.localizedDescription)")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log.error("listener init failed: \(error.localizedDescription, privacy: .public)")
            DiagSink.shared.error("HTTP", "listener init failed: \(error.localizedDescription)")
        }
    }

    /// Broadcast a state-changed event to all subscribed SSE clients. Called
    /// whenever the active profile or profile list changes so the Stream Deck
    /// plugin can update its button highlight without polling.
    func broadcastStateChange() {
        let payload = currentStateJSON()
        let body = "event: state\ndata: \(payload)\n\n"
        sseClients.removeAll { $0.connection.state == .cancelled }
        for c in sseClients {
            c.send(body)
        }
    }

    // MARK: - Connection handling

    private struct SSEClient {
        let connection: NWConnection
        func send(_ text: String) {
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        readRequest(connection: connection, buffer: Data())
    }

    /// Read until we have the full request (headers ended by \r\n\r\n, then
    /// Content-Length bytes of body). Keep-alive isn't supported — one request
    /// per connection, response, close. Stream Deck plugin reconnects per call.
    private func readRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error = error {
                    self.log.info("recv error: \(error.localizedDescription, privacy: .public)")
                    connection.cancel()
                    return
                }
                var buf = buffer
                if let data = data { buf.append(data) }

                guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if isComplete { connection.cancel(); return }
                    self.readRequest(connection: connection, buffer: buf)
                    return
                }
                let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
                let bodyStart = headerEnd.upperBound

                guard let headerStr = String(data: headerData, encoding: .utf8) else {
                    self.respond(connection: connection, status: 400, body: "bad headers")
                    return
                }
                let req = Self.parseRequest(headerStr)
                let contentLength = Int(req.headers["content-length"] ?? "0") ?? 0
                let bodyHave = buf.count - bodyStart
                if bodyHave < contentLength {
                    if isComplete { connection.cancel(); return }
                    self.readRequest(connection: connection, buffer: buf)
                    return
                }
                let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))

                self.route(req: req, body: body, connection: connection)
            }
        }
    }

    private struct Request {
        var method: String = ""
        var path: String = ""
        var headers: [String: String] = [:]
    }

    nonisolated private static func parseRequest(_ raw: String) -> Request {
        var req = Request()
        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first else { return req }
        let parts = first.split(separator: " ", maxSplits: 2)
        if parts.count >= 2 {
            req.method = String(parts[0])
            req.path = String(parts[1])
        }
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).lowercased()
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                req.headers[key] = value
            }
        }
        return req
    }

    // MARK: - Routing

    private func route(req: Request, body: Data, connection: NWConnection) {
        // Skip the per-tick state pulls — only log mutating routes + new SSE
        // subscriptions, so the Diagnostics view shows what Stream Deck did.
        if req.method == "POST" || req.path == "/events" {
            DiagSink.shared.info("HTTP", "\(req.method) \(req.path)")
        }
        switch (req.method, req.path) {
        case ("GET", "/state"):
            respond(connection: connection, status: 200, json: currentStateJSON())

        case ("GET", "/events"):
            // Server-Sent Events stream — kept open, sent state updates on broadcastStateChange.
            startSSE(connection: connection)

        case ("POST", "/profile/load"):
            let name = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["name"] as? String
            guard let name, !name.isEmpty else {
                respond(connection: connection, status: 400, body: "missing name"); return
            }
            delegate?.httpLoadProfile(named: name)
            respond(connection: connection, status: 200, json: currentStateJSON())

        case ("POST", "/profile/next"):
            delegate?.httpCycleProfile(direction: 1)
            respond(connection: connection, status: 200, json: currentStateJSON())

        case ("POST", "/profile/previous"):
            delegate?.httpCycleProfile(direction: -1)
            respond(connection: connection, status: 200, json: currentStateJSON())

        case ("POST", let p) where p.hasPrefix("/button/"):
            let raw = String(p.dropFirst("/button/".count))
            guard let idx = Int(raw), idx >= 0 else {
                respond(connection: connection, status: 400, body: "bad index"); return
            }
            delegate?.httpFireButton(index: idx)
            respond(connection: connection, status: 200, json: "{}")

        case ("POST", "/mute/mic"):
            let value = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["value"] as? Bool
            delegate?.httpSetMicMute(value: value)
            respond(connection: connection, status: 200, json: "{}")

        case ("POST", "/mute/system"):
            let value = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["value"] as? Bool
            delegate?.httpSetSystemMute(value: value)
            respond(connection: connection, status: 200, json: "{}")

        case ("GET", let p) where p.hasPrefix("/log?msg="):
            // Debug channel for the Stream Deck plugin — JS posts here so its
            // event flow shows up in Jnobs's Diagnostics view.
            let encoded = String(p.dropFirst("/log?msg=".count))
            let msg = encoded.removingPercentEncoding ?? encoded
            DiagSink.shared.info("SD-Plugin", msg)
            respond(connection: connection, status: 200, json: "{}")

        default:
            respond(connection: connection, status: 404, body: "not found")
        }
    }

    // MARK: - Responses

    private func currentStateJSON() -> String {
        let snapshot = delegate?.httpCurrentSnapshot() ?? .empty
        let dict: [String: Any] = [
            "activeProfile": snapshot.activeProfile as Any,
            "profiles": snapshot.profileNames,
            "micMuted": snapshot.micMuted,
            "systemMuted": snapshot.systemMuted,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func respond(connection: NWConnection, status: Int, json: String) {
        let body = Data(json.utf8)
        var head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respond(connection: NWConnection, status: Int, body: String) {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        head += "Content-Type: text/plain\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(bodyData)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func startSSE(connection: NWConnection) {
        let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Cache-Control: no-cache\r
            Connection: keep-alive\r
            Access-Control-Allow-Origin: *\r
            \r

            """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let client = SSEClient(connection: connection)
        sseClients.append(client)
        // Send current state immediately so newly-connected client doesn't have to poll.
        client.send("event: state\ndata: \(currentStateJSON())\n\n")
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "?"
        }
    }
}

/// Bridge from HTTP server back to app state. Implemented by the bridging
/// layer that owns AppConfig + ActionRouter.
@MainActor
protocol JnobsHTTPDelegate: AnyObject {
    func httpCurrentSnapshot() -> JnobsHTTPSnapshot
    func httpLoadProfile(named name: String)
    func httpCycleProfile(direction: Int)
    func httpFireButton(index: Int)
    func httpSetMicMute(value: Bool?)        // nil = toggle
    func httpSetSystemMute(value: Bool?)     // nil = toggle
}

struct JnobsHTTPSnapshot: Sendable {
    var activeProfile: String?
    var profileNames: [String]
    var micMuted: Bool
    var systemMuted: Bool

    static let empty = JnobsHTTPSnapshot(
        activeProfile: nil, profileNames: [], micMuted: false, systemMuted: false
    )
}
