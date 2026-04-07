import Foundation
import Network
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "HookServer")

@MainActor
class HookServer {
    private let appState: AppState
    nonisolated static var socketPath: String { SocketPath.path }
    private var unixListener: NWListener?
    private var tcpListener: NWListener?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Clean up stale socket
        unlink(HookServer.socketPath)

        let unixParams = NWParameters()
        unixParams.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        unixParams.requiredLocalEndpoint = NWEndpoint.unix(path: HookServer.socketPath)

        do {
            unixListener = try NWListener(using: unixParams)
        } catch {
            log.error("Failed to create NWListener: \(error.localizedDescription)")
            return
        }

        unixListener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection, defaultOrigin: .local)
            }
        }

        unixListener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log.info("HookServer listening on unix \(HookServer.socketPath)")
            case .failed(let error):
                log.error("HookServer unix listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        unixListener?.start(queue: .main)

        startTCPListener()
    }

    func stop() {
        unixListener?.cancel()
        tcpListener?.cancel()
        unixListener = nil
        tcpListener = nil
        unlink(HookServer.socketPath)
    }

    private func startTCPListener() {
        let localPort = SettingsManager.shared.remoteLocalPort
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(localPort))
        )

        do {
            tcpListener = try NWListener(using: params)
        } catch {
            log.error("Failed to create TCP listener: \(error.localizedDescription)")
            return
        }

        tcpListener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection, defaultOrigin: .remote(profileId: nil, displayName: nil))
            }
        }
        tcpListener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log.info("HookServer listening on tcp 127.0.0.1:\(localPort)")
            case .failed(let error):
                log.error("HookServer TCP listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        tcpListener?.start(queue: .main)
    }

    private func handleConnection(_ connection: NWConnection, defaultOrigin: ConnectionOrigin) {
        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data(), defaultOrigin: defaultOrigin)
    }

    private static let maxPayloadSize = 1_048_576  // 1MB safety limit

    /// Recursively receive all data until EOF, then process
    private func receiveAll(connection: NWConnection, accumulated: Data, defaultOrigin: ConnectionOrigin) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }

                // On error with no data, just drop the connection
                if error != nil && accumulated.isEmpty && content == nil {
                    connection.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                // Safety: reject oversized payloads
                if data.count > Self.maxPayloadSize {
                    log.warning("Payload too large (\(data.count) bytes), dropping connection")
                    connection.cancel()
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: connection, defaultOrigin: defaultOrigin)
                } else {
                    self.receiveAll(connection: connection, accumulated: data, defaultOrigin: defaultOrigin)
                }
            }
        }
    }

    /// Internal tools that are safe to auto-approve without user confirmation.
    private static let autoApproveTools: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop",
        "TodoRead", "TodoWrite",
        "EnterPlanMode", "ExitPlanMode",
    ]

    private func processRequest(data: Data, connection: NWConnection, defaultOrigin: ConnectionOrigin) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendResponse(connection: connection, data: Data("{\"error\":\"parse_failed\"}".utf8))
            return
        }
        guard let event = HookEvent(json: injectConnectionOrigin(into: json, defaultOrigin: defaultOrigin)) else {
            sendResponse(connection: connection, data: Data("{\"error\":\"parse_failed\"}".utf8))
            return
        }

        if let rawSource = event.rawJSON["_source"] as? String,
           SessionSnapshot.normalizedSupportedSource(rawSource) == nil {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        if event.eventName == "PermissionRequest" {
            let sessionId = event.routingSessionId

            // Auto-approve safe internal tools without showing UI
            if let toolName = event.toolName, Self.autoApproveTools.contains(toolName) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // AskUserQuestion is a question, not a permission — route to QuestionBar
            if event.toolName == "AskUserQuestion" {
                monitorPeerDisconnect(connection: connection, sessionId: sessionId)
                Task {
                    let responseBody = await withCheckedContinuation { continuation in
                        appState.handleAskUserQuestion(event, continuation: continuation)
                    }
                    self.sendResponse(connection: connection, data: responseBody)
                }
                return
            }
            monitorPeerDisconnect(connection: connection, sessionId: sessionId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handlePermissionRequest(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }
        } else if EventNormalizer.normalize(event.eventName) == "Notification",
                  QuestionPayload.from(event: event) != nil {
            let questionSessionId = event.routingSessionId
            monitorPeerDisconnect(connection: connection, sessionId: questionSessionId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handleQuestion(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }
        } else {
            appState.handleEvent(event)
            sendResponse(connection: connection, data: Data("{}".utf8))
        }
    }

    /// Per-connection state used by the disconnect monitor.
    /// `responded` flips to true once we've sent the response, so our own
    /// `connection.cancel()` inside `sendResponse` does not masquerade as a
    /// peer disconnect.
    private final class ConnectionContext {
        var responded: Bool = false
    }

    private var connectionContexts: [ObjectIdentifier: ConnectionContext] = [:]

    private enum ConnectionOrigin {
        case local
        case remote(profileId: String?, displayName: String?)
    }

    private func injectConnectionOrigin(into json: [String: Any], defaultOrigin: ConnectionOrigin) -> [String: Any] {
        var merged = json
        if merged["_origin"] == nil {
            switch defaultOrigin {
            case .local:
                merged["_origin"] = "local"
            case .remote:
                merged["_origin"] = "remote"
            }
        }

        if merged["_origin_id"] == nil {
            if let profile = merged["_remote_profile"] as? String, !profile.isEmpty {
                merged["_origin_id"] = "remote:\(profile)"
            } else {
                switch defaultOrigin {
                case .local:
                    merged["_origin_id"] = SessionKey.localOriginId
                case .remote(let profileId, _):
                    if let profileId, !profileId.isEmpty {
                        merged["_origin_id"] = "remote:\(profileId)"
                    } else {
                        merged["_origin_id"] = SessionKey.localOriginId
                    }
                }
            }
        }

        if merged["_origin_display_name"] == nil {
            if let alias = merged["_remote_host_alias"] as? String, !alias.isEmpty {
                merged["_origin_display_name"] = alias
            } else if case .remote(_, let displayName) = defaultOrigin, let displayName, !displayName.isEmpty {
                merged["_origin_display_name"] = displayName
            }
        }

        return merged
    }

    /// Watch for bridge process disconnect — indicates the bridge process actually died
    /// (e.g. user Ctrl-C'd Claude Code), NOT a normal half-close.
    ///
    /// Previously this used `connection.receive(min:1, max:1)` which triggered on EOF.
    /// But the bridge always does `shutdown(SHUT_WR)` after sending the request (see
    /// CodeIslandBridge/main.swift), which produces an immediate EOF on the read side.
    /// That caused every PermissionRequest to be auto-drained as `deny` before the UI
    /// card was even visible. We now rely on `stateUpdateHandler` transitioning to
    /// `cancelled`/`failed` — which only happens on real socket teardown, not half-close.
    private func monitorPeerDisconnect(connection: NWConnection, sessionId: String) {
        let context = ConnectionContext()
        connectionContexts[ObjectIdentifier(connection)] = context

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .cancelled, .failed:
                    if !context.responded {
                        self.appState.handlePeerDisconnect(sessionId: sessionId)
                    }
                    self.connectionContexts.removeValue(forKey: ObjectIdentifier(connection))
                default:
                    break
                }
            }
        }
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        // Mark as responded BEFORE cancel() so the disconnect monitor ignores our own teardown.
        if let context = connectionContexts[ObjectIdentifier(connection)] {
            context.responded = true
        }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
