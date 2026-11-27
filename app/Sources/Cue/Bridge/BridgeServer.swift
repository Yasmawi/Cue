import Foundation
import Network

enum BridgeState: Equatable {
    case stopped
    case listening(port: Int)
    case connected(premiere: String)
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true }; return false }

    var label: String {
        switch self {
        case .stopped: return "Server off"
        case .listening: return "Waiting for Premiere"
        case .connected(let v): return v.isEmpty ? "Connected to Premiere" : "Connected · Premiere \(v)"
        case .failed(let why): return why
        }
    }
}

struct BridgeError: LocalizedError {
    var code: String
    var message: String
    var errorDescription: String? { message }

    static let notConnected = BridgeError(code: "NOT_CONNECTED", message: "Premiere isn't connected. Open Window › UXP Plugins › Cue Bridge in Premiere.")
    static let timeout = BridgeError(code: "TIMEOUT", message: "Premiere didn't answer in time.")
}

/// Localhost WebSocket server. The Cue Bridge UXP plugin connects as a client
/// (UXP can't listen), says hello with the pairing code, then answers
/// requests. One authenticated plugin connection is active at a time.
final class BridgeServer {
    struct Config: Equatable {
        var port: Int
        var pairingCode: String
        var requirePairing: Bool
        var blockBrowserOrigins: Bool
    }

    var onState: ((BridgeState) -> Void)?
    var onEvent: ((String, JSON) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "cue.bridge")
    private var listener: NWListener?
    private var config: Config?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var active: Peer?
    private var pending: [String: (Result<JSON, BridgeError>) -> Void] = [:]
    private var counter = 0
    private var failedHellos: [Date] = []
    private(set) var state: BridgeState = .stopped {
        didSet { let s = state; DispatchQueue.main.async { self.onState?(s) } }
    }

    // MARK: lifecycle

    func start(_ config: Config) {
        queue.async { self._start(config) }
    }

    func stop() {
        queue.async { self._stop(); self.state = .stopped }
    }

    private func _start(_ config: Config) {
        if self.config == config, listener != nil { return }
        _stop()
        self.config = config

        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 32 * 1024 * 1024
        let block = config.blockBrowserOrigins
        ws.setClientRequestHandler(queue) { [weak self] _, headers in
            if block, let origin = headers.first(where: { $0.name.lowercased() == "origin" })?.value.lowercased(),
               Self.isForeignWebOrigin(origin) {
                self?.log("Refused a browser connection from \(origin)")
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }

        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.port)) else {
            state = .failed("Invalid port \(config.port)")
            return
        }
        do {
            let l = try NWListener(using: params, on: port)
            l.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                switch s {
                case .ready:
                    if !(self.active?.authed ?? false) { self.state = .listening(port: config.port) }
                    self.log("Listening on localhost:\(config.port)")
                case .failed(let err):
                    self.state = .failed(Self.describe(err, port: config.port))
                    self.listener?.cancel()
                    self.listener = nil
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener = l
            l.start(queue: queue)
        } catch {
            state = .failed("Couldn't open port \(config.port): \(error.localizedDescription)")
        }
    }

    private func _stop() {
        listener?.cancel()
        listener = nil
        for p in peers.values { p.connection.cancel() }
        peers.removeAll()
        active = nil
        failAll(.notConnected)
        config = nil
    }

    /// A web page's Origin (http/https on some other host). Local origins are allowed.
    private static func isForeignWebOrigin(_ origin: String) -> Bool {
        guard origin.hasPrefix("http://") || origin.hasPrefix("https://"),
              let host = URL(string: origin)?.host?.lowercased() else { return false }
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    private static func describe(_ err: NWError, port: Int) -> String {
        if case .posix(let code) = err, code == .EADDRINUSE { return "Port \(port) is already in use" }
        return "Server error: \(err.localizedDescription)"
    }

    // MARK: connections

    private final class Peer {
        let connection: NWConnection
        var authed = false
        var premiereVersion = ""
        init(_ c: NWConnection) { connection = c }
    }

    private func accept(_ conn: NWConnection) {
        let peer = Peer(conn)
        let key = ObjectIdentifier(peer)
        peers[key] = peer
        conn.stateUpdateHandler = { [weak self, weak peer] s in
            guard let self, let peer else { return }
            switch s {
            case .failed, .cancelled: self.drop(peer)
            default: break
            }
        }
        conn.start(queue: queue)
        receive(peer)
        // A client that never says hello is dropped.
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak peer] in
            guard let self, let peer, !peer.authed, self.peers[ObjectIdentifier(peer)] != nil else { return }
            peer.connection.cancel()
        }
    }

    private func drop(_ peer: Peer) {
        peers.removeValue(forKey: ObjectIdentifier(peer))
        if active === peer {
            active = nil
            failAll(.notConnected)
            log("Premiere disconnected")
            if let c = config, listener != nil { state = .listening(port: c.port) }
        }
    }

    private func receive(_ peer: Peer) {
        peer.connection.receiveMessage { [weak self, weak peer] data, context, _, error in
            guard let self, let peer else { return }
            if let error {
                self.log("Connection error: \(error.localizedDescription)")
                peer.connection.cancel()
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close { peer.connection.cancel(); return }
            if let data, !data.isEmpty, meta?.opcode == .text || meta?.opcode == .binary {
                if let msg = try? JSON.parse(data) { self.handle(msg, from: peer) }
            }
            self.receive(peer)
        }
    }

    private func send(_ msg: JSON, to peer: Peer) {
        guard let data = try? msg.data() else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "cue", metadata: [meta])
        peer.connection.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func handle(_ msg: JSON, from peer: Peer) {
        switch msg["type"]?.string {
        case "hello":
            let token = (msg["token"]?.string ?? "").uppercased()
            failedHellos = failedHellos.filter { $0.timeIntervalSinceNow > -60 }
            if failedHellos.count >= 10 {
                // Something is guessing codes; refuse everything for a minute.
                send(["type": "rejected", "message": "Too many wrong pairing codes. Try again in a minute."], to: peer)
                queue.asyncAfter(deadline: .now() + 0.3) { peer.connection.cancel() }
                return
            }
            if let c = config, c.requirePairing, token != c.pairingCode.uppercased() {
                failedHellos.append(Date())
                log("Rejected Cue Bridge: wrong pairing code")
                send(["type": "rejected", "message": "Wrong pairing code. Copy it from Cue › Settings › Connection."], to: peer)
                queue.asyncAfter(deadline: .now() + 0.3) { peer.connection.cancel() }
                return
            }
            peer.authed = true
            peer.premiereVersion = msg["premiereVersion"]?.string ?? ""
            if let old = active, old !== peer {
                old.connection.cancel()
                failAll(.notConnected)
            }
            active = peer
            send(["type": "welcome", "app": "Cue", "version": .string(AppInfo.version), "protocol": 1], to: peer)
            state = .connected(premiere: peer.premiereVersion)
            log("Cue Bridge connected (plugin \(msg["version"]?.string ?? "?"))")

        case "ping":
            send(["type": "pong", "t": msg["t"] ?? .null], to: peer)

        case "response":
            guard peer.authed, let id = msg["id"]?.string, let done = pending.removeValue(forKey: id) else { return }
            if msg["ok"]?.bool == true {
                done(.success(msg["result"] ?? .null))
            } else {
                let e = msg["error"]
                done(.failure(BridgeError(code: e?["code"]?.string ?? "ERROR", message: e?["message"]?.string ?? "Premiere reported an error.")))
            }

        case "event":
            guard peer.authed, let name = msg["name"]?.string else { return }
            let data = msg["data"] ?? .null
            DispatchQueue.main.async { self.onEvent?(name, data) }

        default:
            break
        }
    }

    private func failAll(_ error: BridgeError) {
        let waiting = pending
        pending.removeAll()
        for (_, done) in waiting { done(.failure(error)) }
    }

    private func log(_ s: String) {
        DispatchQueue.main.async { self.onLog?(s) }
    }

    // MARK: requests

    func request(_ method: String, _ params: JSON = [:], timeout: TimeInterval = 20) async throws -> JSON {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSON, Error>) in
            queue.async {
                guard let peer = self.active, peer.authed else {
                    cont.resume(throwing: BridgeError.notConnected)
                    return
                }
                self.counter += 1
                let id = "r\(self.counter)"
                self.pending[id] = { result in
                    switch result {
                    case .success(let v): cont.resume(returning: v)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
                self.send(["type": "request", "id": .string(id), "method": .string(method), "params": params], to: peer)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let done = self.pending.removeValue(forKey: id) { done(.failure(.timeout)) }
                }
            }
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}
