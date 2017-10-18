//
// Created by Erik Little on 10/14/17.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Dispatch
import Foundation

// TODO Fix the types so that we aren't using concrete types

///
/// A manager for a socket.io connection.
///
/// A `SocketManagerSpec` is responsible for multiplexing multiple namespaces through a single `SocketEngineSpec`.
///
/// Example:
///
/// ```swift
/// let manager = SocketManager(socketURL: URL(string:"http://localhost:8080/")!)
/// let defaultNamespaceSocket = manager.defaultSocket!
/// let swiftSocket = manager.socket(forNamespace: "/swift")
/// // defaultNamespaceSocket and swiftSocket both share a single connection to the server
/// ```
///
@objc
public protocol SocketManagerSpec : class, SocketEngineClient {
    // MARK Properties

    /// Returns the socket associated with the default namespace ("/").
    var defaultSocket: SocketIOClient? { get }

    /// The engine for this manager.
    var engine: SocketEngineSpec? { get set }

    /// If `true` then every time `connect` is called, a new engine will be created.
    var forceNew: Bool { get set }

    // TODO Per socket queues?
    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    var handleQueue: DispatchQueue { get set }

    /// If `true`, this manager will try and reconnect on any disconnects.
    var reconnects: Bool { get set }

    /// The number of seconds to wait before attempting to reconnect.
    var reconnectWait: Int { get set }

    /// The URL of the socket.io server.
    var socketURL: URL { get }

    /// The status of this manager.
    var status: SocketIOStatus { get }

    // MARK: Methods

    /// Connects the underlying transport.
    func connect()

    /// Connects a socket through this manager's engine.
    ///
    /// - parameter socket: The socket who we should connect through this manager.
    func connectSocket(_ socket: SocketIOClient)

    /// Called when the manager has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    func didDisconnect(reason: String)

    /// Disconnects the manager and all associated sockets.
    func disconnect()

    /// Disconnects the given socket.
    ///
    /// - parameter socket: The socket to disconnect.
    func disconnectSocket(_ socket: SocketIOClient)

    /// Disconnects the socket associated with `forNamespace`.
    ///
    /// - parameter forNamespace: The namespace to disconnect from.
    func disconnectSocket(forNamespace nsp: String)

    /// Tries to reconnect to the server.
    ///
    /// This will cause a `disconnect` event to be emitted, as well as an `reconnectAttempt` event.
    func reconnect()

    /// Returns a `SocketIOClient` for the given namespace. This socket shares a transport with the manager.
    ///
    /// - parameter forNamespace: The namespace for the socket.
    /// - returns: A `SocketIOClient` for the given namespace.
    func socket(forNamespace nsp: String) -> SocketIOClient
}

///
/// A manager for a socket.io connection.
///
/// A `SocketManager` is responsible for multiplexing multiple namespaces through a single `SocketEngineSpec`.
///
/// Example:
///
/// ```swift
/// let manager = SocketManager(socketURL: URL(string:"http://localhost:8080/")!)
/// let defaultNamespaceSocket = manager.defaultSocket!
/// let swiftSocket = manager.socket(forNamespace: "/swift")
/// // defaultNamespaceSocket and swiftSocket both share a single connection to the server
/// ```
///
open class SocketManager : NSObject, SocketManagerSpec, SocketParsable, SocketDataBufferable {
    private static let logType = "SocketManager"

    // MARK Properties

    /// The socket associated with the default namespace ("/").
    public var defaultSocket: SocketIOClient? {
        return nsps["/"]
    }

    /// The URL of the socket.io server.
    ///
    /// If changed after calling `init`, `forceNew` must be set to `true`, or it will only connect to the url set in the
    /// init.
    public let socketURL: URL

    /// The configuration for this client.
    ///
    /// **This cannot be set after calling one of the connect methods**.
    public var config: SocketIOClientConfiguration {
        get {
            return _config
        }

        set {
            guard status == .notConnected else {
                DefaultSocketLogger.Logger.error("Tried setting config after calling connect",
                                                 type: SocketManager.logType)
                return
            }

            _config = newValue

            _config.insert(.path("/socket.io/"), replacing: false)
            setConfigs()
        }
    }

    /// The engine for this manager.
    public var engine: SocketEngineSpec?

    /// If `true` then every time `connect` is called, a new engine will be created.
    public var forceNew = false

    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    ///
    /// **This should be a serial queue! Concurrent queues are not supported and might cause crashes and races**.
    public var handleQueue = DispatchQueue.main

    /// The sockets in this manager indexed by namespace.
    public var nsps = [String: SocketIOClient]()

    /// If `true`, this client will try and reconnect on any disconnects.
    public var reconnects = true

    /// The number of seconds to wait before attempting to reconnect.
    public var reconnectWait = 10

    /// The status of this manager.
    public private(set) var status: SocketIOStatus = .notConnected {
        didSet {
            switch status {
            case .connected:
                reconnecting = false
                currentReconnectAttempt = 0
            default:
                break
            }
        }
    }

    /// A list of packets that are waiting for binary data.
    ///
    /// The way that socket.io works all data should be sent directly after each packet.
    /// So this should ideally be an array of one packet waiting for data.
    ///
    /// **This should not be modified directly.**
    public var waitingPackets = [SocketPacket]()

    private(set) var reconnectAttempts = -1

    private var _config: SocketIOClientConfiguration
    private var currentReconnectAttempt = 0
    private var reconnecting = false

    /// Type safe way to create a new SocketIOClient. `opts` can be omitted.
    ///
    /// - parameter socketURL: The url of the socket.io server.
    /// - parameter config: The config for this socket.
    public init(socketURL: URL, config: SocketIOClientConfiguration = []) {
        self._config = config
        self.socketURL = socketURL

        if socketURL.absoluteString.hasPrefix("https://") {
            self._config.insert(.secure(true))
        }

        self._config.insert(.path("/socket.io/"), replacing: false)

        super.init()

        setConfigs()
        nsps["/"] = SocketIOClient(manager: self, nsp: "/")
    }

    /// Not so type safe way to create a SocketIOClient, meant for Objective-C compatiblity.
    /// If using Swift it's recommended to use `init(socketURL: NSURL, options: Set<SocketIOClientOption>)`
    ///
    /// - parameter socketURL: The url of the socket.io server.
    /// - parameter config: The config for this socket.
    @objc
    public convenience init(socketURL: NSURL, config: NSDictionary?) {
        self.init(socketURL: socketURL as URL, config: config?.toSocketConfiguration() ?? [])
    }

    deinit {
        DefaultSocketLogger.Logger.log("Manager is being released", type: SocketManager.logType)

        engine?.disconnect(reason: "Manager Deinit")
    }

    // MARK: Methods

    private func addEngine() {
        DefaultSocketLogger.Logger.log("Adding engine", type: SocketManager.logType)

        engine?.engineQueue.sync {
            self.engine?.client = nil
        }

        engine = SocketEngine(client: self, url: socketURL, config: config)
    }

    /// Connects the underlying transport and the default namespace socket.
    open func connect() {
        guard status == .notConnected || status == .disconnected else {
            // TODO logging
            return
        }

        // TODO forceNew
        if engine == nil {
            addEngine()
        }

        status = .connecting

        engine?.connect()
    }

    /// Connects a socket through this manager's engine.
    ///
    /// - parameter socket: The socket who we should connect through this manager.
    open func connectSocket(_ socket: SocketIOClient) {
        guard status == .connected else {
            DefaultSocketLogger.Logger.log("Tried connecting socket when engine isn't open. Connecting",
                                           type: SocketManager.logType)

            connect()
            return
        }

        engine?.send("0\(socket.nsp)", withData: [])
    }

    /// Called when the manager has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    open func didDisconnect(reason: String) {
        forAll {socket in
            socket.didDisconnect(reason: reason)
        }
    }

    /// Disconnects the manager and all associated sockets.
    open func disconnect() {
        DefaultSocketLogger.Logger.log("Manager closing", type: SocketManager.logType)

        status = .disconnected

        engine?.disconnect(reason: "Disconnect")
    }

    /// Disconnects the given socket.
    ///
    /// This will remove the socket for the manager's control, and make the socket instance useless and ready for
    /// releasing.
    ///
    /// - parameter socket: The socket to disconnect.
    open func disconnectSocket(_ socket: SocketIOClient) {
        // Make sure we remove socket from nsps
        nsps.removeValue(forKey: socket.nsp)

        engine?.send("1\(socket.nsp)", withData: [])
        socket.didDisconnect(reason: "Namespace leave")
    }

    /// Disconnects the socket associated with `forNamespace`.
    ///
    /// This will remove the socket for the manager's control, and make the socket instance useless and ready for
    /// releasing.
    ///
    /// - parameter forNamespace: The namespace to disconnect from.
    open func disconnectSocket(forNamespace nsp: String) {
        guard let socket = nsps.removeValue(forKey: nsp) else {
            DefaultSocketLogger.Logger.log("Could not find socket for \(nsp) to disconnect",
                                           type: SocketManager.logType)

            return
        }

        disconnectSocket(socket)
    }

    /// Sends a packet to all sockets in `nsps`
    ///
    /// - parameter packet: The packet to emit.
    open func emitAll(packet: SocketPacket) {
        forAll {socket in
            socket.handlePacket(packet)
        }
    }

    /// Sends a client event to all sockets in `nsps`
    ///
    /// - parameter clientEvent: The event to emit.
    open func emitAll(clientEvent event: SocketClientEvent, data: [Any]) {
        forAll {socket in
            socket.handleClientEvent(event, data: data)
        }
    }

    /// Sends an event to the server on all namespaces in this manager.
    ///
    /// - parameter event: The event to send.
    /// - parameter items: The data to send with this event.
    open func emitAll(_ event: String, _ items: SocketData...) {
        guard let emitData = try? items.map({ try $0.socketRepresentation() }) else {
            DefaultSocketLogger.Logger.error("Error creating socketRepresentation for emit: \(event), \(items)",
                                             type: SocketManager.logType)

            return
        }

        emitAll(event, withItems: emitData)
    }

    /// Sends an event to the server on all namespaces in this manager.
    ///
    /// Same as `emitAll(_:_:)`, but meant for Objective-C.
    ///
    /// - parameter event: The event to send.
    /// - parameter withItems: The data to send with this event.
    @objc
    open func emitAll(_ event: String, withItems items: [Any]) {
        forAll {socket in
            socket.emit(event, with: items)
        }
    }

    /// Called when the engine closes.
    ///
    /// - parameter reason: The reason that the engine closed.
    open func engineDidClose(reason: String) {
        handleQueue.async {
            self._engineDidClose(reason: reason)
        }
    }

    private func _engineDidClose(reason: String) {
        waitingPackets.removeAll()

        if status != .disconnected {
            status = .notConnected
        }

        if status == .disconnected || !reconnects {
            didDisconnect(reason: reason)
        } else if !reconnecting {
            reconnecting = true
            tryReconnect(reason: reason)
        }
    }

    /// Called when the engine errors.
    ///
    /// - parameter reason: The reason the engine errored.
    open func engineDidError(reason: String) {
        handleQueue.async {
            self._engineDidError(reason: reason)
        }
    }

    private func _engineDidError(reason: String) {
        DefaultSocketLogger.Logger.error("\(reason)", type: SocketManager.logType)

        emitAll(clientEvent: .error, data: [reason])
    }

    /// Called when the engine opens.
    ///
    /// - parameter reason: The reason the engine opened.
    open func engineDidOpen(reason: String) {
        handleQueue.async {
            self._engineDidOpen(reason: reason)
        }
    }

    private func _engineDidOpen(reason: String) {
        DefaultSocketLogger.Logger.log("Engine opened \(reason)", type: SocketManager.logType)

        status = .connected
        nsps["/"]?.didConnect(toNamespace: "/")

        for (nsp, socket) in nsps where nsp != "/" && socket.status == .connecting {
            connectSocket(socket)
        }
    }

    /// Called when the engine receives a pong message.
    open func engineDidReceivePong() {
        handleQueue.async {
            self._engineDidReceivePong()
        }
    }

    private func _engineDidReceivePong() {
        emitAll(clientEvent: .pong, data: [])
    }

    /// Called when the sends a ping to the server.
    open func engineDidSendPing() {
        handleQueue.async {
            self._engineDidSendPing()
        }
    }

    private func _engineDidSendPing() {
        emitAll(clientEvent: .ping, data: [])
    }

    private func forAll(do: (SocketIOClient) throws -> ()) rethrows {
        for (_, socket) in nsps {
            try `do`(socket)
        }
    }

    /// Called when the engine has a message that must be parsed.
    ///
    /// - parameter msg: The message that needs parsing.
    open func parseEngineMessage(_ msg: String) {
        handleQueue.async {
            self._parseEngineMessage(msg)
        }
    }

    private func _parseEngineMessage(_ msg: String) {
        guard let packet = parseSocketMessage(msg) else { return }
        guard packet.type != .binaryAck && packet.type != .binaryEvent else {
            waitingPackets.append(packet)

            return
        }

        nsps[packet.nsp]?.handlePacket(packet)
    }

    /// Called when the engine receives binary data.
    ///
    /// - parameter data: The data the engine received.
    open func parseEngineBinaryData(_ data: Data) {
        handleQueue.async {
            self._parseEngineBinaryData(data)
        }
    }

    private func _parseEngineBinaryData(_ data: Data) {
        guard let packet = parseBinaryData(data) else { return }

        nsps[packet.nsp]?.handlePacket(packet)
    }

    /// Tries to reconnect to the server.
    ///
    /// This will cause a `disconnect` event to be emitted, as well as an `reconnectAttempt` event.
    open func reconnect() {
        guard !reconnecting else { return }

        engine?.disconnect(reason: "manual reconnect")
    }

    private func tryReconnect(reason: String) {
        guard reconnecting else { return }

        DefaultSocketLogger.Logger.log("Starting reconnect", type: SocketManager.logType)
        emitAll(clientEvent: .reconnect, data: [reason])

        _tryReconnect()
    }

    private func _tryReconnect() {
        guard reconnects && reconnecting && status != .disconnected else { return }

        if reconnectAttempts != -1 && currentReconnectAttempt + 1 > reconnectAttempts {
            return didDisconnect(reason: "Reconnect Failed")
        }

        DefaultSocketLogger.Logger.log("Trying to reconnect", type: SocketManager.logType)
        emitAll(clientEvent: .reconnectAttempt, data: [(reconnectAttempts - currentReconnectAttempt)])

        currentReconnectAttempt += 1
        connect()

        handleQueue.asyncAfter(deadline: DispatchTime.now() + Double(reconnectWait), execute: _tryReconnect)
    }

    private func setConfigs() {
        for option in config {
            switch option {
            case let .reconnects(reconnects):
                self.reconnects = reconnects
            case let .reconnectWait(wait):
                reconnectWait = abs(wait)
            case let .log(log):
                DefaultSocketLogger.Logger.log = log
            case let .logger(logger):
                DefaultSocketLogger.Logger = logger
            default:
                continue
            }
        }
    }

    /// Returns a `SocketIOClient` for the given namespace. This socket shares a transport with the manager.
    ///
    /// - parameter forNamespace: The namespace for the socket.
    /// - returns: A `SocketIOClient` for the given namespace.
    open func socket(forNamespace nsp: String) -> SocketIOClient {
        assert(nsp.hasPrefix("/"), "forNamespace must have a leading /")

        if let socket = nsps[nsp] {
            return socket
        }

        let client = SocketIOClient(manager: self, nsp: nsp)

        nsps[nsp] = client

        return client
    }
}
