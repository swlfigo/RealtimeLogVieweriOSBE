//
//  ViewController.swift
//  RealTimeLog
//
//  Created by swlfigo on 04/25/2025.
//  Copyright (c) 2025 swlfigo. All rights reserved.
//

import UIKit
import RealTimeLog
class ViewController: UIViewController {
    
    private var logTimer: Timer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        RealtimeLogMannger.shared.startServer()
        
        // 显示服务器地址
        let label = UILabel()
        label.text = "服务器地址: http://localhost:8080"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        
        // 启动日志发送定时器
        startLogTimer()
    }

    private func startLogTimer() {
        // 每2秒发送一条日志
        logTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {  _ in
            
            // 随机生成日志级别
            let levels = ["info", "warning", "error"]
            let level = levels.randomElement() ?? "info"
            
            // 生成随机日志消息
            let messages = [
                "应用程序启动成功",
                "网络请求超时",
                "用户登录成功",
                "数据库连接失败",
                "文件上传完成",
                "内存使用率过高",
                "缓存清理完成",
                "API调用异常"
            ]
            let message = messages.randomElement() ?? "未知消息"
            
            // 发送日志
            RealtimeLogMannger.shared.sendLog(level: level, message: message)
        }
    }
    
    deinit {
        logTimer?.invalidate()
        logTimer = nil
        RealtimeLogMannger.shared.stopServer()
    }
}

