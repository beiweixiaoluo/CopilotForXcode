import Foundation
import JSONRPC
import LanguageClient
import LanguageServerProtocol
import Logger
import ProcessEnv

/// A clone of the `LocalProcessServer`.
/// We need it because the original one does not allow us to handle custom notifications.
class CopilotLocalProcessServer {
    private let transport: StdioDataTransport
    private let customTransport: CustomDataTransport
    private let process: Process
    private var wrappedServer: CustomJSONRPCLanguageServer?
    var terminationHandler: (() -> Void)?
    @MainActor var ongoingCompletionRequestIDs: [JSONId] = []

    public convenience init(
        path: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) {
        let params = Process.ExecutionParameters(
            path: path,
            arguments: arguments,
            environment: environment
        )

        self.init(executionParameters: params)
    }

    init(executionParameters parameters: Process.ExecutionParameters) {
        transport = StdioDataTransport()
        let framing = SeperatedHTTPHeaderMessageFraming()
        let messageTransport = MessageTransport(
            dataTransport: transport,
            messageProtocol: framing
        )
        customTransport = CustomDataTransport(nextTransport: messageTransport)
        wrappedServer = CustomJSONRPCLanguageServer(dataTransport: customTransport)

        process = Process()

        // Because the implementation of LanguageClient is so closed,
        // we need to get the request IDs from a custom transport before the data
        // is written to the language server.
        customTransport.onWriteRequest = { [weak self] request in
            if request.method == "getCompletionsCycling" {
                Task { @MainActor [weak self] in
                    self?.ongoingCompletionRequestIDs.append(request.id)
                }
            }
        }

        process.standardInput = transport.stdinPipe
        process.standardOutput = transport.stdoutPipe
        process.standardError = transport.stderrPipe

        process.parameters = parameters

        process.terminationHandler = { [unowned self] task in
            self.processTerminated(task)
        }

        process.launch()
    }

    deinit {
        process.terminationHandler = nil
        process.terminate()
        transport.close()
    }

    private func processTerminated(_: Process) {
        transport.close()

        // releasing the server here will short-circuit any pending requests,
        // which might otherwise take a while to time out, if ever.
        wrappedServer = nil
        terminationHandler?()
    }

    var logMessages: Bool {
        get { return wrappedServer?.logMessages ?? false }
        set { wrappedServer?.logMessages = newValue }
    }
}

extension CopilotLocalProcessServer: LanguageServerProtocol.Server {
    public var requestHandler: RequestHandler? {
        get { return wrappedServer?.requestHandler }
        set { wrappedServer?.requestHandler = newValue }
    }

    public var notificationHandler: NotificationHandler? {
        get { wrappedServer?.notificationHandler }
        set { wrappedServer?.notificationHandler = newValue }
    }

    public func sendNotification(
        _ notif: ClientNotification,
        completionHandler: @escaping (ServerError?) -> Void
    ) {
        guard let server = wrappedServer, process.isRunning else {
            completionHandler(.serverUnavailable)
            return
        }

        server.sendNotification(notif, completionHandler: completionHandler)
    }
    
    /// Cancel ongoing completion requests.
    public func cancelOngoingTasks() async {
        guard let server = wrappedServer, process.isRunning else {
            return
        }
        
        let task = Task { @MainActor in
            for id in self.ongoingCompletionRequestIDs {
                switch id {
                case let .numericId(id):
                    try? await server.sendNotification(.protocolCancelRequest(.init(id: id)))
                case let .stringId(id):
                    try? await server.sendNotification(.protocolCancelRequest(.init(id: id)))
                }
            }
            self.ongoingCompletionRequestIDs = []
        }
        
        await task.value
    }

    public func sendRequest<Response: Codable>(
        _ request: ClientRequest,
        completionHandler: @escaping (ServerResult<Response>) -> Void
    ) {
        guard let server = wrappedServer, process.isRunning else {
            completionHandler(.failure(.serverUnavailable))
            return
        }

        server.sendRequest(request, completionHandler: completionHandler)
    }
}

final class CustomJSONRPCLanguageServer: Server {
    let internalServer: JSONRPCLanguageServer

    typealias ProtocolResponse<T: Codable> = ProtocolTransport.ResponseResult<T>

    private let protocolTransport: ProtocolTransport

    public var requestHandler: RequestHandler?
    public var notificationHandler: NotificationHandler?

    private var outOfBandError: Error?

    init(protocolTransport: ProtocolTransport) {
        self.protocolTransport = protocolTransport
        internalServer = JSONRPCLanguageServer(protocolTransport: protocolTransport)

        let previouseRequestHandler = protocolTransport.requestHandler
        let previouseNotificationHandler = protocolTransport.notificationHandler

        protocolTransport
            .requestHandler = { [weak self] in
                guard let self else { return }
                if !self.handleRequest($0, data: $1, callback: $2) {
                    previouseRequestHandler?($0, $1, $2)
                }
            }
        protocolTransport
            .notificationHandler = { [weak self] in
                guard let self else { return }
                if !self.handleNotification($0, data: $1, block: $2) {
                    previouseNotificationHandler?($0, $1, $2)
                }
            }
    }

    convenience init(dataTransport: DataTransport) {
        self.init(protocolTransport: ProtocolTransport(dataTransport: dataTransport))
    }

    deinit {
        protocolTransport.requestHandler = nil
        protocolTransport.notificationHandler = nil
    }

    var logMessages: Bool {
        get { return internalServer.logMessages }
        set { internalServer.logMessages = newValue }
    }
}

extension CustomJSONRPCLanguageServer {
    private func handleNotification(
        _ anyNotification: AnyJSONRPCNotification,
        data: Data,
        block: @escaping (Error?) -> Void
    ) -> Bool {
        let methodName = anyNotification.method
        switch methodName {
        case "window/logMessage":
            if UserDefaults.shared.value(for: \.gitHubCopilotVerboseLog) {
                Logger.gitHubCopilot
                    .info("\(anyNotification.method): \(anyNotification.params.debugDescription)")
            }
            block(nil)
            return true
        case "LogMessage":
            if UserDefaults.shared.value(for: \.gitHubCopilotVerboseLog) {
                Logger.gitHubCopilot
                    .info("\(anyNotification.method): \(anyNotification.params.debugDescription)")
            }
            block(nil)
            return true
        case "statusNotification":
            if UserDefaults.shared.value(for: \.gitHubCopilotVerboseLog) {
                Logger.gitHubCopilot
                    .info("\(anyNotification.method): \(anyNotification.params.debugDescription)")
            }
            block(nil)
            return true
        case "featureFlagsNotification":
            if UserDefaults.shared.value(for: \.gitHubCopilotVerboseLog) {
                Logger.gitHubCopilot
                    .info("\(anyNotification.method): \(anyNotification.params.debugDescription)")
            }
            block(nil)
            return true
        default:
            return false
        }
    }

    public func sendNotification(
        _ notif: ClientNotification,
        completionHandler: @escaping (ServerError?) -> Void
    ) {
        internalServer.sendNotification(notif, completionHandler: completionHandler)
    }
}

extension CustomJSONRPCLanguageServer {
    private func handleRequest(
        _ request: AnyJSONRPCRequest,
        data: Data,
        callback: @escaping (AnyJSONRPCResponse) -> Void
    ) -> Bool {
        return false
    }
}

extension CustomJSONRPCLanguageServer {
    public func sendRequest<Response: Codable>(
        _ request: ClientRequest,
        completionHandler: @escaping (ServerResult<Response>) -> Void
    ) {
        internalServer.sendRequest(request, completionHandler: completionHandler)
    }
}

