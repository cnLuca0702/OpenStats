import Foundation
import Localization
import Network

/// 监控大屏的 HTTP 服务：NWListener 上跑一个极简 HTTP/1.1，一连接一个请求（Connection: close）。
/// 只服务三个只读端点（页面 / 指标 / 存活），不解析请求体；
/// 页面按当前界面语言现生成，指标快照由 DashboardController 提前备好，这里只负责收发。
/// 监听是否成功不通过回调通知（避免跨线程闭包），控制器在采样循环里读 currentState 轮询
final class DashboardServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var ready = false
    private var failureReason: String?
    /// 页面内容；每次请求现取，切换界面语言后刷新即生效
    private let pageProvider: @Sendable () -> Data
    /// 最新的 /metrics 内容，由控制器的采样循环更新
    private let metricsProvider: @Sendable () -> Data
    /// 一次连接最长保留时间：迟迟不发完请求头的连接到点就断开
    static let connectionTimeout: TimeInterval = 10

    init(page: @escaping @Sendable () -> Data, metricsProvider: @escaping @Sendable () -> Data) {
        self.pageProvider = page
        self.metricsProvider = metricsProvider
    }

    // MARK: 生命周期

    /// 开始监听指定端口；端口冲突等异步失败写进 currentState
    func start(port: UInt16) {
        lock.lock()
        listener?.cancel()
        listener = nil
        ready = false
        failureReason = nil
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any) else {
            failureReason = tr("无法在端口 \(port) 上监听")
            lock.unlock()
            return
        }
        self.listener = listener
        lock.unlock()

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.noteState(of: listener, ready: true, reason: nil)
            case .failed(let error):
                self.noteState(of: listener, ready: false, reason: error.localizedDescription)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: .global())
    }

    func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        ready = false
        failureReason = nil
        lock.unlock()
    }

    /// 最近一次监听状态；未调用过 start 或已停止时为 nil
    func currentState() -> (ready: Bool, reason: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard listener != nil else { return nil }
        if ready { return (true, nil) }
        if let failureReason { return (false, failureReason) }
        return nil   // 还在启动中
    }

    /// 换端口后旧监听器迟到的回调不能覆盖新监听器的状态
    private func noteState(of source: NWListener, ready: Bool, reason: String?) {
        lock.lock()
        guard source === listener else {
            lock.unlock()
            return
        }
        self.ready = ready
        self.failureReason = reason
        lock.unlock()
    }

    // MARK: 连接处理

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        // 已经正常关闭的连接再 cancel 一次没有影响
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.connectionTimeout) {
            connection.cancel()
        }
        receiveRequest(connection, buffered: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buffer = buffered
            if let data { buffer.append(data) }
            // 头没收全就继续收；超过 16KB 或对端写完还没出现头也不再等
            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete, buffer.count < 16_384 {
                self.receiveRequest(connection, buffered: buffer)
                return
            }
            let requestLine = String(decoding: buffer.prefix(8192), as: UTF8.self)
                .split(separator: "\r\n", maxSplits: 1).first.map(String.init)
            let path = requestLine?.split(separator: " ").dropFirst().first.map(String.init)
            let response = Self.makeResponse(path: path, html: self.pageProvider(), metrics: self.metricsProvider())
            connection.send(content: response.data, contentContext: .defaultMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// 一次 HTTP 响应：状态行 + 头 + 正文，已拼好待发送
struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    var data: Data {
        let reason = Self.reasons[status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static let reasons: [Int: String] = [200: "OK", 404: "Not Found"]
}

extension DashboardServer {
    /// 纯函数：按路径生成响应，便于单测；页面与指标只在命中对应路径时才生成
    static func makeResponse(path: String?, html: @autoclosure () -> Data, metrics: @autoclosure () -> Data) -> HTTPResponse {
        let path = path?.split(separator: "?").first.map(String.init) ?? "/"
        switch path {
        case "/", "/index.html":
            return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: html())
        case "/metrics":
            return HTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: metrics())
        case "/healthz":
            return HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data("ok".utf8))
        default:
            return HTTPResponse(status: 404, contentType: "text/plain; charset=utf-8", body: Data("not found".utf8))
        }
    }
}
