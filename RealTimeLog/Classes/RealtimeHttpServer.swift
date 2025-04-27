//
//  RealtimeHttpServer.swift
//  RealTimeLog
//
//  Created by sylar on 2025/4/25.
//

import Foundation
import CocoaAsyncSocket
import CommonCrypto

class RealtimeHttpServer : NSObject{
    private var socket: GCDAsyncSocket?
    private var port: UInt16 = 8080
    private let webRootDir : URL?
    private let queue = DispatchQueue(label: "com.httpserver.queue", qos: .userInitiated)
    private let requestQueue = DispatchQueue(label: "com.httpserver.requestQueue", qos: .userInitiated)
    private var activeConnections = Set<GCDAsyncSocket>()
    private var webSocketConnections = Set<GCDAsyncSocket>()
    private var requestCounters = [GCDAsyncSocket: Int]()
    private let maxRequestsPerConnection = 10
    private let requestTimeout: TimeInterval = 5.0
    
    // 添加日志队列
    private let logQueue = DispatchQueue(label: "com.httpserver.logQueue", qos: .userInitiated)
    
    init(port:UInt16 = 8080) {
        let frameworkBundle = Bundle(for: RealtimeLogMannger.self)
        webRootDir =  frameworkBundle.resourceURL?.appendingPathComponent("WebBundle.bundle").appendingPathComponent("web")
        self.port = port
        super.init()
    }
    
    // 添加发送日志的方法
    func sendLog(level: String, message: String) {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 创建日志JSON
            let logData: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "level": level,
                "message": message
            ]
            
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: logData)
                self.sendWebSocketMessage(data: jsonData)
            } catch {
                print("Failed to serialize log: \(error)")
            }
        }
    }
    
    // 发送WebSocket消息
    private func sendWebSocketMessage(data: Data) {
        // 创建WebSocket帧
        var frame = Data()
        
        // 添加帧头
        frame.append(0x81) // FIN + Text frame
        
        // 添加长度
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
        
        // 添加数据
        frame.append(data)
        
        // 发送到所有WebSocket连接
        webSocketConnections.forEach { socket in
            socket.write(frame, withTimeout: requestTimeout, tag: 0)
        }
    }
    
    func start() {
        socket = GCDAsyncSocket(delegate: self, delegateQueue: queue)
        
        do {
            try socket?.accept(onPort: port)
            print("HTTP服务器已启动，监听端口: \(port)")
        } catch {
            print("启动服务器失败: \(error)")
        }
    }
    
    func stop() {
        activeConnections.forEach { $0.disconnect() }
        webSocketConnections.forEach { $0.disconnect() }
        activeConnections.removeAll()
        webSocketConnections.removeAll()
        requestCounters.removeAll()
        socket?.disconnect()
        socket = nil
    }
    
    private func handleWebSocketUpgrade(_ request: String, socket: GCDAsyncSocket) -> (statusCode: Int, headers: [String: String], body: Data?) {
        let lines = request.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        
        // 解析请求头
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        
        // 验证WebSocket请求
        guard let key = headers["Sec-WebSocket-Key"],
              headers["Upgrade"]?.lowercased() == "websocket",
              headers["Connection"]?.lowercased().contains("upgrade") == true else {
            return (400, ["Content-Type": "text/plain"], "Bad Request".data(using: .utf8))
        }
        
        // 生成WebSocket Accept Key
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let concatenated = key + magic
        let sha1 = concatenated.data(using: .utf8)!.sha1
        let acceptKey = sha1.base64EncodedString()
        
        // 将连接添加到WebSocket连接集合
        webSocketConnections.insert(socket)
        
        // 返回升级响应
        return (101, [
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": acceptKey
        ], nil)
    }
    
    private func handleRequest(_ request: String, socket: GCDAsyncSocket) -> (statusCode: Int, headers: [String: String], body: Data?) {
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
        
        // 检查是否是WebSocket升级请求
        if path == "/ws" && method == "GET" {
            return handleWebSocketUpgrade(request, socket: socket)
        }
        
        // 处理普通HTTP请求
        if path == "/" {
            path = "/index.html"
        }
        
        guard let p = webRootDir?.path , let u = URL.init(string: p) else {
            return (404, ["Content-Type": "text/plain"], "Not Found".data(using: .utf8))
        }
        let finalPath =  u.appendingPathComponent(path)
        
        
        let exist = FileManager.default.fileExists(atPath: finalPath.absoluteString)
        if !exist {
            return (404, ["Content-Type": "text/plain"], "Not Found".data(using: .utf8))
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: finalPath.absoluteString))
            
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
    
    private func incrementRequestCounter(for socket: GCDAsyncSocket) -> Bool {
        requestQueue.sync {
            let count = requestCounters[socket, default: 0] + 1
            requestCounters[socket] = count
            return count <= maxRequestsPerConnection
        }
    }
    
    private func resetRequestCounter(for socket: GCDAsyncSocket) {
        requestQueue.sync {
            requestCounters[socket] = 0
        }
    }
    
}


extension RealtimeHttpServer: GCDAsyncSocketDelegate {
    public func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        newSocket.delegate = self
        newSocket.delegateQueue = queue
        activeConnections.insert(newSocket)
        resetRequestCounter(for: newSocket)
        newSocket.readData(to: "\r\n\r\n".data(using: .utf8)!, withTimeout: requestTimeout, tag: 0)
    }
    
    public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        if webSocketConnections.contains(sock) {
            // 处理WebSocket数据帧
            if data.count >= 2 {
                let firstByte = data[0]
                
                // 检查是否是关闭帧
                if (firstByte & 0x0F) == 0x08 {
                    sock.disconnect()
                    return
                }
                
                // 检查是否是Ping帧
                if (firstByte & 0x0F) == 0x09 {
                    // 发送Pong响应
                    var pongFrame = Data()
                    pongFrame.append(0x8A) // FIN + Pong frame
                    pongFrame.append(0x00) // 空数据
                    sock.write(pongFrame, withTimeout: requestTimeout, tag: 0)
                    return
                }
            }
            
            // 继续读取数据
            sock.readData(withTimeout: requestTimeout, tag: 0)
            return
        }
        
        if !incrementRequestCounter(for: sock) {
            sock.disconnect()
            return
        }
        
        if let request = String(data: data, encoding: .utf8) {
            let response = handleRequest(request, socket: sock)
            
            var responseString = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"
            
            for (key, value) in response.headers {
                responseString += "\(key): \(value)\r\n"
            }
            
            responseString += "\r\n"
            
            if let body = response.body {
                var responseData = responseString.data(using: .utf8)!
                responseData.append(body)
                sock.write(responseData, withTimeout: requestTimeout, tag: 0)
            } else {
                sock.write(responseString.data(using: .utf8), withTimeout: requestTimeout, tag: 0)
            }
        }
        
        if !webSocketConnections.contains(sock) {
            sock.readData(to: "\r\n\r\n".data(using: .utf8)!, withTimeout: requestTimeout, tag: 0)
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
        // 写入完成后不关闭连接
    }
    
    public func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        activeConnections.remove(sock)
        webSocketConnections.remove(sock)
        requestCounters.removeValue(forKey: sock)
        if let error = err {
            print("连接断开，错误: \(error)")
        }
    }
}

// SHA1扩展
extension Data {
    fileprivate var sha1: Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        self.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(self.count), &digest)
        }
        return Data(digest)
    }
}
