//
//  RealtimeLogMannger.swift
//  RealTimeLog
//
//  Created by sylar on 2025/4/25.
//

import Foundation
import OSLog
public class RealtimeLogMannger {
    
    public static let shared = RealtimeLogMannger()
    
    private var httpServer : RealtimeHttpServer?
    
    public func startServer(port:UInt16 = 8080) {
        httpServer = RealtimeHttpServer(port: port)
        httpServer?.start()
    }
    
    public func sendLog(level: String, message: String) {
        httpServer?.sendLog(level: level, message: message)
    }
    
    public func stopServer(){
        httpServer?.stop()
    }
    
}
