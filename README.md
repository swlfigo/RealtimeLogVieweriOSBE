# RealTimeLog

iOS实时网页输出Log工具

基于 Apple Network.framework (NWListener / NWConnection) 搭建 LocalServer，无第三方依赖

前端UI页面 [RealtimeLog FE](https://github.com/SerenitySpace/RealtimeLogViewerFE)

若对UI修改,打包后替换 Pod/Assets 下 WebBundle/web 文件

### 安装

```shell
# Git Tag 引用
pod 'RealTimeLog', :git => 'https://github.com/SerenitySpace/RealtimeLogVieweriOSBE.git', :tag => '1.1.0'

# 或本地路径引用
pod 'RealTimeLog', :path => '/Path/To/RealtimeLogVieweriOSBE'
```

> 要求 iOS 12.0+



## Usage

```swift
//默认端口8080,可自定义端口(如修改,需要手动修改Bundle中ws端口)
RealtimeLogMannger.shared.startServer()

// 日志级别
// OSLogType.info ; OSLogType.error ; OSLogType.fault
RealtimeLogMannger.shared.sendLog(level: OSLogType.info, message: message)


//电脑浏览器访问手机ip:8080 即可查看实时Log前端页面
```

