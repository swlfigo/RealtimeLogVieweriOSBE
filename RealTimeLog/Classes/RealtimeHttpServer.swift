//
//  RealtimeHttpServer.swift
//  RealTimeLog
//
//  Created by sylar on 2025/4/25.
//

import Foundation
import Network
import CommonCrypto

class RealtimeHttpServer {

    // MARK: - ClientConnection wrapper (makes NWConnection hashable for Set)

    private final class ClientConnection: Hashable {
        let connection: NWConnection
        let id: ObjectIdentifier
        init(_ c: NWConnection) { connection = c; id = ObjectIdentifier(c) }
        static func == (l: ClientConnection, r: ClientConnection) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    // MARK: - Properties

    private var listener: NWListener?
    private var port: UInt16 = 8080
    private let webRootDir: URL?
    private let queue = DispatchQueue(label: "com.httpserver.queue", qos: .userInitiated)
    private var activeConnections = Set<ClientConnection>()
    private var webSocketConnections = Set<ClientConnection>()

    private let logQueue = DispatchQueue(label: "com.httpserver.logQueue", qos: .userInitiated)

    init(port: UInt16 = 8080) {
        let frameworkBundle = Bundle(for: RealtimeLogMannger.self)
        webRootDir = frameworkBundle.resourceURL?.appendingPathComponent("WebBundle.bundle").appendingPathComponent("web")
        self.port = port
    }

    // MARK: - Public API

    func sendLog(level: String, message: String) {
        logQueue.async { [weak self] in
            guard let self = self else { return }

            let logData: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "level": level,
                "message": message
            ]

            do {
                let jsonData = try JSONSerialization.data(withJSONObject: logData)
                self.queue.async {
                    self.sendWebSocketMessage(data: jsonData)
                }
            } catch {
                print("Failed to serialize log: \(error)")
            }
        }
    }

    func start() {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                print("启动服务器失败: 无效端口 \(port)")
                return
            }
            listener = try NWListener(using: .tcp, on: nwPort)
        } catch {
            print("启动服务器失败: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener?.port {
                    print("HTTP服务器已启动，监听端口: \(port)")
                }
            case .failed(let error):
                print("服务器监听失败: \(error)")
                self?.listener?.cancel()
            default:
                break
            }
        }

        listener?.start(queue: queue)
    }

    func stop() {
        activeConnections.forEach { $0.connection.cancel() }
        webSocketConnections.forEach { $0.connection.cancel() }
        activeConnections.removeAll()
        webSocketConnections.removeAll()
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let client = ClientConnection(connection)
        activeConnections.insert(client)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                print("连接失败: \(error)")
                self?.cleanupConnection(client)
            case .cancelled:
                self?.cleanupConnection(client)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveHTTPRequest(client: client, buffer: Data())
    }

    private func receiveHTTPRequest(client: ClientConnection, buffer: Data) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("读取数据错误: \(error)")
                self.cleanupConnection(client)
                return
            }

            var accumulated = buffer
            if let content = content {
                accumulated.append(content)
            }

            if let separator = "\r\n\r\n".data(using: .utf8),
               accumulated.range(of: separator) != nil {
                if let request = String(data: accumulated, encoding: .utf8) {
                    self.processHTTPRequest(request, client: client)
                }
            } else if isComplete {
                self.cleanupConnection(client)
            } else {
                self.receiveHTTPRequest(client: client, buffer: accumulated)
            }
        }
    }

    // MARK: - HTTP Processing

    private func processHTTPRequest(_ request: String, client: ClientConnection) {
        let response = handleRequest(request, client: client)

        var responseString = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"

        for (key, value) in response.headers {
            responseString += "\(key): \(value)\r\n"
        }

        responseString += "\r\n"

        var responseData = responseString.data(using: .utf8)!
        if let body = response.body {
            responseData.append(body)
        }

        client.connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("发送响应错误: \(error)")
                self.cleanupConnection(client)
                return
            }

            if self.webSocketConnections.contains(client) {
                self.receiveWebSocketFrame(client: client)
            } else {
                self.receiveHTTPRequest(client: client, buffer: Data())
            }
        })
    }

    private func handleRequest(_ request: String, client: ClientConnection) -> (statusCode: Int, headers: [String: String], body: Data?) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            return (400, ["Content-Type": "text/plain"], "Bad Request".data(using: .utf8))
        }

        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 2 else {
            return (400, ["Content-Type": "text/plain"], "Bad Request".data(using: .utf8))
        }

        let method = components[0]
        var path = components[1]

        if path == "/ws" && method == "GET" {
            return handleWebSocketUpgrade(request, client: client)
        }

        if path == "/" {
            path = "/index.html"
        }

        guard let rootPath = webRootDir?.path else {
            return (404, ["Content-Type": "text/plain"], "Not Found".data(using: .utf8))
        }

        let finalPath = URL(fileURLWithPath: rootPath).appendingPathComponent(path)

        guard FileManager.default.fileExists(atPath: finalPath.path) else {
            return (404, ["Content-Type": "text/plain"], "Not Found".data(using: .utf8))
        }

        do {
            let data = try Data(contentsOf: finalPath)

            let contentType: String
            if path.hasSuffix(".html") {
                contentType = "text/html; charset=utf-8"
            } else if path.hasSuffix(".css") {
                contentType = "text/css; charset=utf-8"
            } else if path.hasSuffix(".js") {
                contentType = "application/javascript; charset=utf-8"
            } else if path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") {
                contentType = "image/jpeg"
            } else if path.hasSuffix(".png") {
                contentType = "image/png"
            } else {
                contentType = "application/octet-stream"
            }

            let headers: [String: String] = [
                "Content-Type": contentType,
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type",
                "Access-Control-Max-Age": "86400",
                "Connection": "keep-alive",
                "Keep-Alive": "timeout=5, max=1000",
                "Content-Length": "\(data.count)"
            ]

            if method == "OPTIONS" {
                return (204, headers, nil)
            }

            return (200, headers, data)
        } catch {
            return (500, ["Content-Type": "text/plain"], "Internal Server Error".data(using: .utf8))
        }
    }

    private func handleWebSocketUpgrade(_ request: String, client: ClientConnection) -> (statusCode: Int, headers: [String: String], body: Data?) {
        let lines = request.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]

        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        guard let key = headers["Sec-WebSocket-Key"],
              headers["Upgrade"]?.lowercased() == "websocket",
              headers["Connection"]?.lowercased().contains("upgrade") == true else {
            return (400, ["Content-Type": "text/plain"], "Bad Request".data(using: .utf8))
        }

        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let concatenated = key + magic
        let sha1 = concatenated.data(using: .utf8)!.sha1
        let acceptKey = sha1.base64EncodedString()

        webSocketConnections.insert(client)

        return (101, [
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": acceptKey
        ], nil)
    }

    // MARK: - WebSocket

    private func receiveWebSocketFrame(client: ClientConnection) {
        client.connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("WebSocket读取错误: \(error)")
                self.cleanupConnection(client)
                return
            }

            guard let data = content, data.count >= 2 else {
                if isComplete {
                    self.cleanupConnection(client)
                }
                return
            }

            let firstByte = data[0]
            let opcode = firstByte & 0x0F

            // Close frame
            if opcode == 0x08 {
                self.cleanupConnection(client)
                return
            }

            // Ping frame — reply with Pong
            if opcode == 0x09 {
                var pongFrame = Data()
                pongFrame.append(0x8A) // FIN + Pong
                pongFrame.append(0x00)
                client.connection.send(content: pongFrame, completion: .contentProcessed { [weak self] _ in
                    self?.receiveWebSocketFrame(client: client)
                })
                return
            }

            // Continue reading
            self.receiveWebSocketFrame(client: client)
        }
    }

    private func sendWebSocketMessage(data: Data) {
        var frame = Data()

        frame.append(0x81) // FIN + Text frame

        if data.count <= 125 {
            frame.append(UInt8(data.count))
        } else if data.count <= UInt16.max {
            frame.append(126)
            frame.append(UInt8((data.count >> 8) & 0xFF))
            frame.append(UInt8(data.count & 0xFF))
        } else {
            frame.append(127)
            for i in 0..<8 {
                frame.append(UInt8((data.count >> ((7 - i) * 8)) & 0xFF))
            }
        }

        frame.append(data)

        webSocketConnections.forEach { client in
            client.connection.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    print("WebSocket发送错误: \(error)")
                }
            })
        }
    }

    // MARK: - Cleanup

    private func cleanupConnection(_ client: ClientConnection) {
        activeConnections.remove(client)
        webSocketConnections.remove(client)
        client.connection.cancel()
    }
}

// MARK: - SHA1扩展
extension Data {
    fileprivate var sha1: Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        self.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(self.count), &digest)
        }
        return Data(digest)
    }
}
