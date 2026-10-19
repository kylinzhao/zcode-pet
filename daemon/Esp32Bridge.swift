// Esp32Bridge — zcode-pet → FoloToy AI Passport（ESP32-C3）UDP 桥接
//
// Mac 是任务状态唯一权威；设备端只做「状态镜像 + 帧播放器」，零本地计数（防语义分叉）。
// 传输：UDP / 8765，单行 JSON UTF-8，≤512B。协议字段与固件侧（ai-passport zcp_bridge.c）
// 完全一致——改任何字段必须同步该仓库并跑 scripts/check_esp32_bridge.sh。
//
// 消息（v 固定 1）：
//   hello  设备→Mac（每 5s 广播 255.255.255.255:8765）
//          {"v":1,"t":"hello","name":"zcode-pet","fw":"1.0.0"}
//   status Mac→设备（每 2s；状态变化即时补发；在线单播、6s 无 ACK 降级广播）
//          {"v":1,"t":"status","seq":N,"mode":"idle|working|celebrate|error",
//           "tier":0..3,"run":N,"unread":N,"mid":M,"n":可选数字,"ts":毫秒}
//          mode/tier/run/unread/mid/n 全部来自 PetDisplayState 快照（与宠物文案同源）
//   ack    设备→Mac {"v":1,"t":"ack","seq":N}（回执最近一次收到的 status）
//   read   设备→Mac {"v":1,"t":"read"}（设备 OK 键 = 已读确认，走 ReadWatermark 水位，
//          桌面角标与设备镜像同一过滤语义；不改写 ZCode DB）
//
// 链路：hello 学设备 IP → online；6s 无 ACK → degraded（改广播发送）；10s 无任何设备包
// → offline（菜单栏 tooltip 给诊断提示）。AP/客户端隔离的 WiFi 下广播与单播均不可达，
// 协议层不做穿透，由设备端 mid=16 与本端 tooltip 文案提示换网/热点。
//
// 配网（USB 串口，独立于本文件的传输通道）：scripts/provision_esp32.sh 发送一行
//   "ZCP <ssid> <pass>"（pass 可含空格），设备回执 "ZCP-ACK <ssid>" / "ZCP-ERR <原因>"。
//
// 自检：--bridge-selftest [device_strings.txt]（无 GUI、无网络；scripts/check_esp32_bridge.sh 调用）

import Foundation

// MARK: - 设备 OK 已读水位

/// 设备端 OK 键触发的已读确认：记录确认时刻（ms），updateUI 统计未读时过滤
/// `unread_at <= 水位` 的行。持久化在 ~/.zcode-pet/read_watermark，重启后仍生效；
/// 不改写 ZCode 的 tasks DB（只读约定）——用户在 ZCode 内打开任务才会真正清 DB 未读。
enum ReadWatermark {
    static var path: String { PetConfig.dataDir + "/read_watermark" }

    static func load() -> Double {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8), let v = Double(s) else { return 0 }
        return v
    }

    static func save(ms: Double) {
        try? "\(ms)".write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - 链路状态

enum BridgeLink: String {
    case online, degraded, offline
}

// MARK: - UDP 桥接

final class Esp32Bridge {
    static let port: UInt16 = 8765
    static let protoVersion = 1
    static let sendInterval: TimeInterval = 2.0     // 周期 status 兜底
    static let pushThrottle: TimeInterval = 0.25    // 状态变化即时补发的最小间隔
    static let ackTimeout: TimeInterval = 6.0       // 无 ACK → 降级广播
    static let offlineTimeout: TimeInterval = 10.0  // 无任何设备包 → offline（与设备端 10s 看门狗对称）

    var stateProvider: (() -> PetDisplayState?)?    // 主线程取最新快照（AppDelegate 提供）
    var onRead: (() -> Void)?                       // 设备 OK 键 → 已读确认
    var linkDidChange: ((BridgeLink) -> Void)?

    private(set) var link: BridgeLink = .offline {
        didSet { if link != oldValue { linkDidChange?(link) } }
    }
    private(set) var peerIP: String?
    private(set) var degraded = false
    private var lastHelloAt: Double = 0
    private var lastAckAt: Double = 0
    private var lastDevicePacketAt: Double = 0
    private var seq = 0
    private(set) var lastSentSeq = -1
    private var lastSentAt: Double = 0
    private var latestState: PetDisplayState?

    // BSD UDP socket（全部 I/O 在主队列；守护进程本就单线程事件循环）
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var sendTimer: Timer?
    private var watchdog: Timer?

    // MARK: 生命周期

    func start() {
        guard fd < 0 else { return }
        guard openSocket() else {
            NSLog("[zcode-pet] esp32 bridge: udp/\(Self.port) 绑定失败（旧实例占用？）桥接停用")
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.drainSocket() }
        src.resume()
        readSource = src
        sendTimer = Timer.scheduledTimer(withTimeInterval: Self.sendInterval, repeats: true) { [weak self] _ in
            self?.sendTick()
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick(now: Date().timeIntervalSince1970)
        }
        NSLog("[zcode-pet] esp32 bridge: listening on udp/\(Self.port)，等设备 hello 广播")
    }

    func stop() {
        readSource?.cancel(); readSource = nil
        sendTimer?.invalidate(); sendTimer = nil
        watchdog?.invalidate(); watchdog = nil
        if fd >= 0 { close(fd) }
        fd = -1
    }

    /// 菜单栏 tooltip（offline 时给网络环境诊断提示）
    var tooltip: String {
        switch link {
        case .online: return "设备已连接：\(peerIP ?? "?")"
        case .degraded: return "设备响应不稳（丢 ACK），已降级广播发送"
        case .offline: return "设备未响应：确认与 Mac 同一 WiFi（路由器客户端隔离会同时挡住广播与单播）"
        }
    }

    // MARK: 协议编解码（纯函数，--bridge-selftest 覆盖）

    static func wireMode(_ m: PetMode) -> String {
        switch m {
        case .idle: return "idle"
        case .working: return "working"
        case .celebrate: return "celebrate"
        case .error: return "error"
        }
    }

    /// status 帧；n 仅在非 nil 时出现（协议可选字段）
    static func statusJSON(seq: Int, state: PetDisplayState, tsMs: Double) -> Data? {
        var o: [String: Any] = ["v": protoVersion, "t": "status", "seq": seq,
                                "mode": wireMode(state.mode), "tier": state.tier,
                                "run": state.run, "unread": state.unread,
                                "mid": state.mid, "ts": Int64(tsMs)]
        if let n = state.n { o["n"] = n }
        return try? JSONSerialization.data(withJSONObject: o)
    }

    private static func message(_ data: Data) -> [String: Any]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["v"] as? Int) == protoVersion else { return nil }
        return obj
    }

    static func isHello(_ data: Data) -> Bool { message(data)?["t"] as? String == "hello" }
    static func isRead(_ data: Data) -> Bool { message(data)?["t"] as? String == "read" }
    static func ackSeq(_ data: Data) -> Int? {
        guard let o = message(data), o["t"] as? String == "ack" else { return nil }
        return o["seq"] as? Int
    }

    // MARK: 状态机（now 由外部注入，便于自检）

    /// 收到设备包：hello 学 IP 复活、ack 回执、read 转已读
    func ingest(data: Data, from ip: String, now: TimeInterval) {
        guard let obj = Esp32Bridge.message(data) else { return }
        switch obj["t"] as? String {
        case "hello":
            peerIP = ip
            lastHelloAt = now
            lastDevicePacketAt = now
            degraded = false
            link = .online
        case "ack":
            lastDevicePacketAt = now
            if Esp32Bridge.ackSeq(data) == lastSentSeq {
                lastAckAt = now
                degraded = false
                if link != .offline { link = .online }
            }
        case "read":
            lastDevicePacketAt = now
            onRead?()
        default:
            break
        }
    }

    /// 看门狗：6s 无 ACK 降级广播；10s 无任何设备包判离线（等 hello 重学 IP）
    func tick(now: TimeInterval) {
        guard link != .offline else { return }
        let lastPacket = max(lastHelloAt, lastAckAt)
        guard lastPacket > 0 else { return }
        if now - lastPacket >= Self.offlineTimeout {
            link = .offline
            degraded = false
            peerIP = nil
        } else if !degraded, lastSentSeq >= 0, now - lastAckAt >= Self.ackTimeout {
            degraded = true
            link = .degraded
        }
    }

    /// 状态变化入口（updateUI 每 2s 轮询都会调；变化才即时补发）
    func push(_ s: PetDisplayState) {
        let changed = s != latestState
        latestState = s
        guard link != .offline, changed, Date().timeIntervalSince1970 - lastSentAt > Self.pushThrottle else { return }
        sendNow(s)
    }

    // MARK: 发送

    private func sendTick() {
        guard link != .offline else { return }
        guard let s = stateProvider?() ?? latestState else { return }
        latestState = s
        sendNow(s)   // 周期兜底：把 tick 期内的子态变化（犯困/余韵）也带上
    }

    private func sendNow(_ s: PetDisplayState) {
        seq += 1
        lastSentSeq = seq
        lastSentAt = Date().timeIntervalSince1970
        guard let data = Esp32Bridge.statusJSON(seq: seq, state: s, tsMs: lastSentAt * 1000) else { return }
        let target = (degraded || peerIP == nil) ? "255.255.255.255" : peerIP!
        udpSend(data, to: target)
    }

    // MARK: BSD socket

    private func openSocket() -> Bool {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(s); return false }
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)   // 读事件循环里非阻塞收干净
        fd = s
        return true
    }

    private func drainSocket() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let n = recvfrom(fd, &buf, buf.count, 0, &addr, &len)
            guard n > 0 else { return }
            guard addr.sa_family == sa_family_t(AF_INET) else { continue }
            let sin = withUnsafeBytes(of: addr) { $0.load(as: sockaddr_in.self) }
            let ip = String(cString: inet_ntoa(sin.sin_addr))
            ingest(data: Data(buf[0..<n]), from: ip, now: Date().timeIntervalSince1970)
        }
    }

    private func udpSend(_ data: Data, to ip: String) {
        guard fd >= 0 else { return }   // fd<0 = 自检模式：只走状态机不发真包
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        let sent = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                data.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { NSLog("[zcode-pet] esp32 bridge: sendto \(ip) errno=\(errno)") }
    }
}

// MARK: - --bridge-selftest（无 GUI / 无网络 / 无设备）

/// 伪造状态序列断言协议编码、链路状态机与文案同步；stringsPath 给出时
/// 额外断言 device_strings.txt 的 # sync: 区与桌面 update() 文案逐条一致。
func runBridgeSelfTest(stringsPath: String?) -> Int32 {
    print("== zcode-pet esp32 bridge self-test ==")
    var failed = 0
    func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond {
            print("  ✓ \(name)")
        } else {
            failed += 1
            print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    // 保存/恢复 PetArt 动态参数（测试注入后还原，不影响其余自检）
    let saved = (PetArt.ballTime, PetArt.workTier, PetArt.drowsiness, PetArt.deepSleep,
                 PetArt.impatience, PetArt.pat, PetArt.perk, PetArt.aftermath, PetArt.comboCount)
    defer {
        PetArt.resetDynamic()
        PetArt.ballTime = saved.0; PetArt.workTier = saved.1; PetArt.drowsiness = saved.2
        PetArt.deepSleep = saved.3; PetArt.impatience = saved.4; PetArt.pat = saved.5
        PetArt.perk = saved.6; PetArt.aftermath = saved.7; PetArt.comboCount = saved.8
    }
    func art(_ setup: () -> Void, _ body: () -> Void) {
        PetArt.resetDynamic()
        setup()
        body()
        PetArt.resetDynamic()
    }

    // ---- A. PetDisplayState 判定语义（与桌面 update() 同源） ----
    print("[A] PetDisplayState 判定")
    art({ PetArt.deepSleep = 1 }) {
        let s = PetDisplayState.snapshot(mode: .idle, run: 0, unread: 2)
        check("idle 深睡 → mid1/tier0", s.mid == 1 && s.tier == 0)
    }
    art({ PetArt.aftermath = 0.5 }) {
        check("idle 余韵 → mid2", PetDisplayState.snapshot(mode: .idle, run: 0, unread: 0).mid == 2)
    }
    art({ PetArt.drowsiness = 0.9 }) {
        check("idle 打盹 → mid3", PetDisplayState.snapshot(mode: .idle, run: 0, unread: 0).mid == 3)
    }
    check("idle 平静 → mid4", PetDisplayState.snapshot(mode: .idle, run: 0, unread: 0).mid == 4)
    art({ PetArt.impatience = 0.5 }) {
        let s = PetDisplayState.snapshot(mode: .working, run: 1, unread: 0)
        check("working 不耐烦 → mid5", s.mid == 5)
    }
    let s1 = PetDisplayState.snapshot(mode: .working, run: 1, unread: 0)
    let s3 = PetDisplayState.snapshot(mode: .working, run: 3, unread: 0)
    let s5 = PetDisplayState.snapshot(mode: .working, run: 5, unread: 0)
    let s0 = PetDisplayState.snapshot(mode: .working, run: 0, unread: 0)
    check("working 1个 → mid6/tier1", s1.mid == 6 && s1.tier == 1)
    // tier 归档式与桌面 tick 一致：run>=4 ? 3 : max(1, run)——run=3 即 tier3（文案仍是并行档 mid7）
    check("working 3个 → mid7/tier3/n=3", s3.mid == 7 && s3.tier == 3 && s3.n == 3)
    check("working 5个 → mid8/tier3/n=5", s5.mid == 8 && s5.tier == 3 && s5.n == 5)
    check("working 0个兜底 → mid9", s0.mid == 9)
    art({ PetArt.comboCount = 3 }) {
        let s = PetDisplayState.snapshot(mode: .celebrate, run: 0, unread: 0)
        check("celebrate 连击 → mid11/n=3", s.mid == 11 && s.n == 3)
    }
    check("celebrate 普通 → mid10", PetDisplayState.snapshot(mode: .celebrate, run: 0, unread: 0).mid == 10)
    check("error → mid15", PetDisplayState.snapshot(mode: .error, run: 0, unread: 0).mid == 15)

    // ---- B. 桌面文案字面量（caption 单一来源） ----
    print("[B] 桌面文案")
    check("mid7 文案", s3.caption == "3 个任务并行中…", s3.caption)
    check("mid8 文案", s5.caption == "5 个任务！忙翻了", s5.caption)
    art({ PetArt.deepSleep = 1 }) {
        let c = PetDisplayState.snapshot(mode: .idle, run: 0, unread: 5).caption
        check("mid1 文案带未读后缀", c == "呼呼大睡 😴 · 5 未读", c)
    }
    art({ PetArt.comboCount = 3 }) {
        let c = PetDisplayState.snapshot(mode: .celebrate, run: 0, unread: 0).caption
        check("mid11 文案", c == "连击 ×3 完成！！", c)
    }

    // ---- C. status JSON 编码 ----
    print("[C] status 编码")
    let json = Esp32Bridge.statusJSON(seq: 7, state: s3, tsMs: 1_700_000_000_000)
    check("statusJSON 可编码", json != nil)
    if let data = json {
        check("status ≤512B", data.count <= 512, "\(data.count)B")
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        check("字段 v/t/seq", obj?["v"] as? Int == 1 && obj?["t"] as? String == "status" && obj?["seq"] as? Int == 7)
        check("字段 mode/tier/run/unread",
              obj?["mode"] as? String == "working" && obj?["tier"] as? Int == 3 &&
              obj?["run"] as? Int == 3 && obj?["unread"] as? Int == 0)
        check("字段 mid/n/ts", obj?["mid"] as? Int == 7 && obj?["n"] as? Int == 3 &&
              obj?["ts"] as? Int64 == 1_700_000_000_000)
        let noN = Esp32Bridge.statusJSON(seq: 8, state: s1, tsMs: 0)
        let o2 = noN.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        check("n 缺省不出现（可选字段）", o2?["n"] == nil)
    }

    // ---- D. hello / ack / read 解析 ----
    print("[D] 消息解析")
    let hello = Data("{\"v\":1,\"t\":\"hello\",\"name\":\"zcode-pet\",\"fw\":\"1.0.0\"}".utf8)
    let read = Data("{\"v\":1,\"t\":\"read\"}".utf8)
    let ack = Data("{\"v\":1,\"t\":\"ack\",\"seq\":7}".utf8)
    let garbage = Data("{\"v\":2,\"t\":\"hello\"}".utf8)
    check("hello 解析", Esp32Bridge.isHello(hello))
    check("read 解析", Esp32Bridge.isRead(read))
    check("ack seq 解析", Esp32Bridge.ackSeq(ack) == 7)
    check("版本不符拒绝", !Esp32Bridge.isHello(garbage) && Esp32Bridge.ackSeq(garbage) == nil)

    // ---- E. 链路状态机（注入时钟） ----
    print("[E] 链路状态机")
    let b = Esp32Bridge()
    var readCount = 0
    b.onRead = { readCount += 1 }
    let t0: TimeInterval = 1_000_000
    b.ingest(data: hello, from: "192.168.1.23", now: t0)
    check("hello → online + 学到 IP", b.link == .online && b.peerIP == "192.168.1.23")
    b.push(s3)
    let ackOfLast = Data("{\"v\":1,\"t\":\"ack\",\"seq\":\(b.lastSentSeq)}".utf8)
    b.ingest(data: ackOfLast, from: "192.168.1.23", now: t0 + 1)
    check("ack 回执保持 online", b.link == .online)
    b.tick(now: t0 + 7)
    check("6s 无 ACK → degraded", b.link == .degraded && b.degraded)
    b.ingest(data: ackOfLast, from: "192.168.1.23", now: t0 + 8)
    check("ack 恢复 online", b.link == .online && !b.degraded)
    b.ingest(data: hello, from: "192.168.1.99", now: t0 + 9)
    check("hello 重学 IP（DHCP 换址无感）", b.peerIP == "192.168.1.99")
    b.tick(now: t0 + 19.5)
    check("10s 无设备包 → offline", b.link == .offline && b.peerIP == nil)
    b.ingest(data: hello, from: "192.168.1.99", now: t0 + 20)
    check("hello 复活", b.link == .online)
    b.ingest(data: read, from: "192.168.1.99", now: t0 + 21)
    check("read → 已读回调", readCount == 1)
    check("offline tooltip 带诊断", Esp32Bridge().tooltip.contains("同一 WiFi"))

    // ---- F. device_strings.txt 同步断言（仅 # sync: 区） ----
    if let path = stringsPath {
        print("[F] device_strings.txt 同步断言")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("  ✗ 读不到 \(path)"); return 1
        }
        let file = DeviceStrings.parse(text)
        check("sync 区恰 12 条", file.sync.count == 12, "实际 \(file.sync.count)")

        // 桌面 12 条合成文案：快照 → caption → 设备投影 → 与文件逐条比对
        let syncCases: [(Int, PetMode, () -> Void)] = [
            (1, .idle, { PetArt.deepSleep = 1 }),
            (2, .idle, { PetArt.aftermath = 0.5 }),
            (3, .idle, { PetArt.drowsiness = 0.9 }),
            (4, .idle, {}),
            (5, .working, { PetArt.impatience = 0.5 }),
            (6, .working, {}),
            (7, .working, {}),
            (8, .working, {}),
            (9, .working, {}),
            (10, .celebrate, {}),
            (11, .celebrate, { PetArt.comboCount = 3 }),
            (15, .error, {}),
        ]
        let runByMid = [7: 3, 8: 5, 9: 0]
        for (mid, mode, setup) in syncCases {
            art(setup) {
                let run = runByMid[mid] ?? 1
                let s = PetDisplayState.snapshot(mode: mode, run: run, unread: 0)
                let projected = DeviceStrings.syncProjection(mid: mid, caption: s.caption)
                let want = file.syncText(mid) ?? "<缺 mid\(mid)>"
                check("mid\(mid) 同步（\(projected)）", projected == want,
                      projected == want ? "" : "桌面投影「\(projected)」 vs 文件「\(want)」")
            }
        }

        // 结构断言：mid 1-16 全覆盖恰一次；device 区无 emoji/表外字符
        check("mid 1-16 全覆盖恰一次", file.midCoverageOK(), file.midCoverageDetail)
        for entry in file.device {
            let bad = DeviceStrings.outsideCharset(entry.text)
            check("device 区 \(entry.key) 字符集", bad.isEmpty, bad.joined(separator: " "))
        }
    } else {
        print("[F] device_strings.txt 未提供，跳过文案同步断言")
    }

    print("== bridge self-test \(failed == 0 ? "done ==" : "FAILED (\(failed)) ==")")
    return failed == 0 ? 0 : 1
}

// MARK: - device_strings.txt 解析（selftest 与 gen 脚本共用同一格式契约）
//
//   # sync:      ← 桌面同步区（数字 key = 协议 mid 1-11/15）
//   1 = 呼呼大睡
//   # device:    ← 设备专属区（数字 mid 12-14/16 + 大写符号名，固件生成 ZCP_STR_<SYMBOL>）
//   12 = 连接 WiFi 中…
//   条目 `key = text`；数字模板 %d 原文内嵌（设备端 snprintf，数字走 Montserrat fallback）；
//   # 开头为注释。

struct DeviceStrings {
    struct Entry {
        let key: String
        let text: String
    }
    let sync: [Entry]      // key = "1".."16"
    let device: [Entry]    // key = 数字 mid 或大写符号

    static func parse(_ text: String) -> DeviceStrings {
        var section = 0   // 0 头部 1 sync 2 device
        var sync: [Entry] = []
        var device: [Entry] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# sync:") { section = 1; continue }
            if line.hasPrefix("# device:") { section = 2; continue }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let sep = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<sep]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            switch section {
            case 1: sync.append(Entry(key: key, text: value))
            case 2: device.append(Entry(key: key, text: value))
            default: break
            }
        }
        return DeviceStrings(sync: sync, device: device)
    }

    func syncText(_ mid: Int) -> String? {
        sync.first { $0.key == "\(mid)" }?.text
    }

    var midCoverageDetail: String {
        var seen: [Int: Int] = [:]
        for e in sync + device {
            if let n = Int(e.key) { seen[n, default: 0] += 1 }
        }
        let missing = (1...16).filter { (seen[$0] ?? 0) == 0 }
        let dup = seen.filter { $0.value > 1 }.map { "mid\($0.key)×\($0.value)" }
        let stray = seen.keys.filter { !(1...16).contains($0) }.sorted().map { "mid\($0)" }
        return (missing.map { "缺 mid\($0)" } + dup + stray).joined(separator: " ")
    }

    func midCoverageOK() -> Bool { midCoverageDetail.isEmpty }

    /// 去 emoji 投影：保留 ASCII 可打印 / ·×…！→ 箭头 / 全角逗号顿号句号 / CJK；丢 emoji 及变体选择符
    static func deEmojified(_ s: String) -> String {
        let kept = String(s.unicodeScalars.filter { scalar -> Bool in
            switch scalar.value {
            case 0x20...0x7E, 0x00B7, 0x00D7, 0x2026, 0xFF01, 0x2190...0x2193, 0xFF0C, 0x3001, 0x3002, 0x3000...0x9FFF: return true
            default: return false
            }
        })
        return kept.trimmingCharacters(in: .whitespaces)
    }

    /// 桌面 caption → 设备 sync 文案的投影：数字替换为 %d 模板。
    /// 唯一非机械项是 mid11：方案协议区明确设备端显示「连击完成」（连击数走可选 n 字段，
    /// 设备端不渲染次数），故桌面「连击 ×N 完成！！」投影为固定文案。
    static func syncProjection(mid: Int, caption: String) -> String {
        if mid == 11 { return "连击完成" }
        var out = ""
        for ch in caption {
            if ch.isNumber { out += "%d" } else { out.append(ch) }
        }
        return deEmojified(out)
    }

    /// 表外字符检查：与 deEmojified 同一白名单；返回越界字符的描述（含码点）
    static func outsideCharset(_ s: String) -> [String] {
        var bad: [String] = []
        for scalar in s.unicodeScalars {
            var ok = false
            switch scalar.value {
            case 0x20...0x7E, 0x00B7, 0x00D7, 0x2026, 0xFF01, 0x2190...0x2193, 0xFF0C, 0x3001, 0x3002, 0x3000...0x9FFF: ok = true
            default: break
            }
            if !ok {
                let desc = "U+\(String(scalar.value, radix: 16, uppercase: true))「\(String(scalar))」"
                if !bad.contains(desc) { bad.append(desc) }
            }
        }
        return bad
    }
}
