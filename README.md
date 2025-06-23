# RealTimeLog

iOS实时网页输出Log工具

基于 CocoaAsyncSokcet 搭建LocalServer

前端UI页面 [RealtimeLog FE](https://github.com/SerenitySpace/RealtimeLogViewerFE)

若对UI修改,打包后替换 Pod/Assets 下 WebBundle/web 文件

Pod没有发布,可以使用本地相对引用路劲引入

```shell
pod 'RealTimeLog' , :path => '/Path/To/RealTimeLog/Podspec'
```



## Usage

```swift
//默认端口8080,可自定义端口(如修改,需要手动修改Bundle中ws端口)
RealtimeLogMannger.shared.startServer()

// 日志级别
// OSLogType.info ; OSLogType.error ; OSLogType.fault
RealtimeLogMannger.shared.sendLog(level: OSLogType.info, message: message)


//电脑浏览器访问手机ip:8080 即可查看实时Log前端页面
```

