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
    
    public func sendLog(logLevel level:OSLogType, message: String) {
        var levelInfo = "info"
        if level == .fault {
            levelInfo = "warning"
        } else if level == .error {
            levelInfo = "error"
        }
        httpServer?.sendLog(level: levelInfo, message: message)
    }
    
    public func stopServer(){
        httpServer?.stop()
    }
    
}
