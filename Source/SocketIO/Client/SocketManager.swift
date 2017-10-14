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

@objc
public protocol SocketManagerSpec : class, SocketEngineClient {
    // MARK Properties

    /// The engine for this manager.
    var engine: SocketEngineSpec? { get set }

    /// If `true` then every time `connect` is called, a new engine will be created.
    var forceNew: Bool { get set }

    /// The queue that all interaction with the client should occur on. This is the queue that event handlers are
    /// called on.
    var handleQueue: DispatchQueue { get set }

    /// If `true`, this manager will try and reconnect on any disconnects.
    var reconnects: Bool { get set }

    /// The number of seconds to wait before attempting to reconnect.
    var reconnectWait: Int { get set }

    /// The status of this manager.
    var status: SocketManagerStatus { get }

    // MARK: Methods

    /// Connects the underlying transport.
    func connect()

    /// Called when the manager has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    func didDisconnect(reason: String)

    /// Tries to reconnect to the server.
    ///
    /// This will cause a `disconnect` event to be emitted, as well as an `reconnectAttempt` event.
    func reconnect()
}

open class SocketManager : NSObject, SocketManagerSpec, SocketParsable, SocketDataBufferable {
    private static let logType = "SocketManager"

    // MARK Properties

    /// The URL of the socket.io server.
    ///
    /// If changed after calling `init`, `forceNew` must be set to `true`, or it will only connect to the url set in the
    /// init.
    @objc
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
    public var nsps = [String: SocketIOClientSpec]()

    /// If `true`, this client will try and reconnect on any disconnects.
    public var reconnects = true

    /// The number of seconds to wait before attempting to reconnect.
    public var reconnectWait = 10

    /// The status of this manager.
    public private(set) var status: SocketManagerStatus = .notConnected

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

    /// Connects the underlying transport.
    open func connect() {
        // TODO connect
        // TODO handle force new
    }

    /// Called when the manager has disconnected from socket.io.
    ///
    /// - parameter reason: The reason for the disconnection.
    open func didDisconnect(reason: String) {
        // TODO emit disconnect to everyone
    }

    /// Sends a packet to all sockets in `nsps`
    ///
    /// - parameter packet: The packet to emit.
    open func emitAll(packet: SocketPacket) {

    }

    /// Sends a client event to all sockets in `nsps`
    ///
    /// - parameter clientEvent: The event to emit.
    open func emitAll(clientEvent event: SocketClientEvent, data: [Any]) {
        for (_, socket) in nsps {
            socket.handleClientEvent(event, data: data)
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

//        guard nsp != "/" else {
//            didConnect(toNamespace: "/")
//
//            return
//        }
//
//        joinNamespace(nsp)

        // TODO Handle open
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


    /// Called when the engine has a message that must be parsed.
    ///
    /// - parameter msg: The message that needs parsing.
    open func parseEngineMessage(_ msg: String) {
        handleQueue.async {
            self.parseEngineMessage(msg)
        }
    }

    private func _parseEngineMessage(_ msg: String) {
        guard let packet = parseSocketMessage(msg) else { return }

        nsps[packet.nsp]?.handlePacket(packet)
    }

    /// Called when the engine receives binary data.
    ///
    /// - parameter data: The data the engine received.
    open func parseEngineBinaryData(_ data: Data) {
        handleQueue.async {
            self.parseEngineBinaryData(data)
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
}

/// Represents the state of a manager.
@objc
public enum SocketManagerStatus : Int {
    /// The manager is connected.
    case connected

    /// The manager is in the process of connecting.
    case connecting

    /// The manager is disconnected and will not attempt to reconnect.
    case disconnected

    /// The manager has just been created.
    case notConnected
}
