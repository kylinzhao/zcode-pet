// DeviceBridge — zcode-pet → FoloToy AI Passport（ESP32-C3）BLE GATT 桥接
//
// Mac 是任务状态唯一权威；设备端只做「状态镜像 + 帧播放器」，零本地计数（防语义分叉）。
// 传输：BLE GATT，Mac=中心（CoreBluetooth），设备=外设（NimBLE，常驻广播）。单行 JSON
// UTF-8，status ≤512B 走 write-with-response（preferred MTU 256，协商更小时由 ATT long
// write 自动分块重装，协议层零自定义分块）。协议字段与固件侧（ai-passport zcp_bridge.c）
// 完全一致——改任何字段必须同步该仓库并跑 scripts/check_esp32_bridge.sh（[4/4] 校验
// 两侧 UUID 逐字节一致）。
//
// UUID（与固件 zcp_bridge.h 三常量一一对应，勿单侧改动）：
//   Service 5A1C0001-7BCD-4E0F-9A2B-3D5E6F8091A2（5A1C=zcode-pet Comms 助记）
//   TX      5A1C0002-…（设备→Mac，NOTIFY，max_len 64）
//   RX      5A1C0003-…（Mac→设备，WRITE 带响应，max_len 512）
//
// 消息（v 固定 1，与 UDP 版字段完全一致）：
//   hello  设备→Mac notify（每 5s）{"v":1,"t":"hello","name":"zcode-pet","fw":"1.0.0"}
//   status Mac→设备 write RX（每 2s 周期兜底 + 变化即时补发 0.25s 节流）
//          {"v":1,"t":"status","seq":N,"mode":"idle|working|celebrate|error",
//           "tier":0..3,"run":N,"unread":N,"mid":M,"n":可选数字,"ts":毫秒}
//          mode/tier/run/unread/mid/n 全部来自 PetDisplayState 快照（与宠物文案同源）
//   ack    设备→Mac notify {"v":1,"t":"ack","seq":N}（回执；ATT 写回执本身逐包确认，
//          ack 仅作 10s 看门狗输入）
//   read   设备→Mac notify {"v":1,"t":"read"}（设备 OK 键 = 已读确认，走 ReadWatermark
//          水位，桌面角标与设备镜像同一过滤语义；不改写 ZCode DB）
//
// 链路（围绕「广播在不在、GATT 连没连」，UDP 的 degraded 广播降级态取消）：
//   poweredOn → 按服务 UUID 扫描 → connect → discoverServices → setNotifyValue(TX)
//   → 订阅成功 = online；didDisconnect → offline → 退避重扫（0/1/2/5s 封顶）；
//   10s 无设备包（hello/ack/read 任一）→ 看门狗判死 → 断开重扫。链路自愈，无需按键。
//
// 自检：--bridge-selftest [device_strings.txt]（无 GUI、无网络、不创建 CBCentralManager
// ——不触发 TCC 授权弹窗；scripts/check_esp32_bridge.sh 调用）

import CoreBluetooth
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

// MARK: - 链路状态机（纯逻辑，注入时钟，主机可测——不触碰 CoreBluetooth）

/// BLE 链路五相：idle（未启动）→ scanning → connecting → online（TX 已订阅）→
/// offline（断开/看门狗判死，按退避表计划重扫）。所有转移显式判断当前相，
/// 重复回调（如 cancel 与 didDisconnect 先后到达）幂等。
struct DeviceLink {
    static let offlineTimeout: TimeInterval = 10.0          // 无设备包判死（与设备端对称）
    static let rescanBackoff: [TimeInterval] = [0, 1, 2, 5] // 断开后重扫退避（封顶 5s）

    enum Phase: Equatable {
        case idle, scanning, connecting, online, offline
    }

    /// tick 建议的外部动作
    enum Action: Equatable {
        case none
        case scan        // phase=offline 且退避到期：开始扫描
        case dropPeer    // phase=online 且看门狗判死：cancel 连接（didDisconnect 接力）
    }

    private(set) var phase: Phase = .idle
    private(set) var rescanAttempt = 0
    private(set) var lastPacketAt: TimeInterval = 0      // 最近 hello/ack/read/订阅时刻
    private(set) var nextScanAt: TimeInterval = 0        // 退避后的最早重扫时刻

    mutating func scanStarted(now: TimeInterval) {
        guard phase == .idle || phase == .offline else { return }
        phase = .scanning
    }

    mutating func discovered(now: TimeInterval) {
        guard phase == .scanning else { return }
        phase = .connecting
    }

    /// TX notify 订阅成功 = online；同时视作一次设备侧活动
    mutating func subscribed(now: TimeInterval) {
        phase = .online
        rescanAttempt = 0
        lastPacketAt = now
    }

    mutating func disconnected(now: TimeInterval) {
        guard phase != .offline, phase != .idle else { return }
        phase = .offline
        scheduleRescan(now: now)
    }

    /// 排队下一次重扫：按退避表取延迟并推进计数（判死与断开回调共用，后到者幂等）
    private mutating func scheduleRescan(now: TimeInterval) {
        let delay = Self.rescanBackoff[min(rescanAttempt, Self.rescanBackoff.count - 1)]
        rescanAttempt += 1
        nextScanAt = now + delay
    }

    /// 收到设备包（hello/ack/read 任一）：喂看门狗
    mutating func packet(now: TimeInterval) {
        lastPacketAt = now
        if phase == .connecting { phase = .online }      // 提前于订阅回执的保险
    }

    mutating func tick(now: TimeInterval) -> Action {
        switch phase {
        case .online:
            guard lastPacketAt > 0, now - lastPacketAt >= Self.offlineTimeout else { return .none }
            phase = .offline
            scheduleRescan(now: now)
            return .dropPeer
        case .offline:
            return now >= nextScanAt ? .scan : .none
        default:
            return .none
        }
    }
}

// MARK: - BLE 桥接（CoreBluetooth 中心）

final class DeviceBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // UUID 三常量：与 ai-passport main/zcp_bridge.h 逐字节一致（check_esp32_bridge.sh [4/4] 把关）
    static let serviceUUID = CBUUID(string: "5A1C0001-7BCD-4E0F-9A2B-3D5E6F8091A2")
    static let txUUID      = CBUUID(string: "5A1C0002-7BCD-4E0F-9A2B-3D5E6F8091A2") // 设备→Mac notify
    static let rxUUID      = CBUUID(string: "5A1C0003-7BCD-4E0F-9A2B-3D5E6F8091A2") // Mac→设备 write
    static let deviceName = "zcode-pet"
    static let protoVersion = 1
    static let sendInterval: TimeInterval = 2.0     // 周期 status 兜底
    static let pushThrottle: TimeInterval = 0.25    // 状态变化即时补发的最小间隔
    static let maxStatusBytes = 512                 // RX 特征上限；发送前断言

    var stateProvider: (() -> PetDisplayState?)?    // 主线程取最新快照（AppDelegate 提供）
    var onRead: (() -> Void)?                       // 设备 OK 键 → 已读确认
    var linkDidChange: ((DeviceLink.Phase) -> Void)?

    // internal var：selftest 直驱状态机注入事件（类属性 var 上的结构体 mutating 调用原地写回）
    var link = DeviceLink() {
        didSet { if link.phase != oldValue.phase { linkDidChange?(link.phase) } }
    }

    // 蓝牙子系统诊断（tooltip 用；仅 start() 创建 CBCentralManager 后才有值）
    private var btState: CBManagerState = .unknown

    private var central: CBCentralManager?          // 只在 start() 创建（selftest 不碰 TCC）
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var latestState: PetDisplayState?
    private var seq = 0
    private(set) var lastSentSeq = -1
    private var lastSentAt: TimeInterval = 0
    private var sendTimer: Timer?
    private var watchdog: Timer?

    // MARK: 生命周期

    func start() {
        guard central == nil else { return }
        // queue: nil = 回调走主队列，与守护进程单线程事件循环一致
        central = CBCentralManager(delegate: self, queue: nil)
        sendTimer = Timer.scheduledTimer(withTimeInterval: Self.sendInterval, repeats: true) { [weak self] _ in
            self?.sendTick()
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.watchdogTick(now: Date().timeIntervalSince1970)
        }
        NSLog("[zcode-pet] device bridge: BLE 中心启动，扫描服务 \(Self.serviceUUID)")
    }

    func stop() {
        sendTimer?.invalidate(); sendTimer = nil
        watchdog?.invalidate(); watchdog = nil
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        peripheral = nil; txChar = nil; rxChar = nil
    }

    /// 菜单栏 tooltip（蓝牙诊断）
    var tooltip: String {
        switch btState {
        case .poweredOff:
            return "Mac 蓝牙已关闭：打开系统设置 → 蓝牙后自动恢复连接"
        case .unauthorized:
            return "无蓝牙权限：系统设置 → 隐私与安全性 → 蓝牙，允许 zcode-pet"
        case .unsupported:
            return "本机不支持 BLE"
        default:
            break
        }
        switch link.phase {
        case .online: return "设备已连接：zcode-pet（BLE GATT）"
        case .scanning, .connecting: return "正在搜索 zcode-pet 设备…"
        case .offline, .idle: return "设备未连接：确认设备已上电（自动搜索，断开即重连）"
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

    // MARK: 状态机入口（now 注入，selftest 直驱；线上路径经 didUpdateValueFor）

    /// 收到设备包：hello/ack/read 任一都喂看门狗；read 转已读回调
    func ingest(data: Data, now: TimeInterval) {
        guard let obj = DeviceBridge.message(data) else { return }
        switch obj["t"] as? String {
        case "hello", "ack":
            link.packet(now: now)
        case "read":
            link.packet(now: now)
            onRead?()
        default:
            break
        }
    }

    /// 状态变化入口（updateUI 每 2s 轮询都会调；变化才即时补发）
    func push(_ s: PetDisplayState) {
        let changed = s != latestState
        latestState = s
        guard link.phase == .online, changed,
              Date().timeIntervalSince1970 - lastSentAt > Self.pushThrottle else { return }
        sendNow(s)
    }

    // MARK: 发送

    private func sendTick() {
        guard link.phase == .online else { return }
        guard let s = stateProvider?() ?? latestState else { return }
        latestState = s
        sendNow(s)   // 周期兜底：把 tick 期内的子态变化（犯困/余韵）也带上
    }

    private func sendNow(_ s: PetDisplayState) {
        guard let p = peripheral, let rx = rxChar else { return }
        seq += 1
        lastSentSeq = seq
        lastSentAt = Date().timeIntervalSince1970
        guard let data = DeviceBridge.statusJSON(seq: seq, state: s, tsMs: lastSentAt * 1000) else { return }
        assert(data.count <= Self.maxStatusBytes, "status 帧超 RX 特征上限：\(data.count)B")
        guard data.count <= Self.maxStatusBytes else { return }
        // write-with-response：ATT 层逐包确认；MTU 不足时 CoreBluetooth 自动走
        // Prepare/Execute long write（NimBLE 侧自动重装，回调收到完整 buffer）
        p.writeValue(data, for: rx, type: .withResponse)
    }

    private func watchdogTick(now: TimeInterval) {
        switch link.tick(now: now) {
        case .dropPeer:
            NSLog("[zcode-pet] device bridge: 10s 无设备包，判死重连")
            if let p = peripheral { central?.cancelPeripheralConnection(p) }
            peripheral = nil; txChar = nil; rxChar = nil
            startScan(now: now)                               // 判死即扫，不等 didDisconnect
        case .scan:
            startScan(now: now)
        case .none:
            break
        }
    }

    private func startScan(now: TimeInterval = Date().timeIntervalSince1970) {
        guard let central, central.state == .poweredOn else { return }
        link.scanStarted(now: now)
        // 按服务 UUID 过滤扫描（macOS 主动扫描，可收齐 scan response 里的完整设备名）
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        btState = central.state
        linkDidChange?(link.phase)                            // tooltip 随蓝牙子系统状态刷新
        switch central.state {
        case .poweredOn:
            startScan()
        case .poweredOff, .unauthorized, .unsupported:
            central.stopScan()
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil; txChar = nil; rxChar = nil
            if link.phase != .idle { link.disconnected(now: Date().timeIntervalSince1970) }
            NSLog("[zcode-pet] device bridge: 蓝牙不可用 state=\(central.state.rawValue)，待恢复")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard link.phase == .scanning else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        link.discovered(now: Date().timeIntervalSince1970)
        NSLog("[zcode-pet] device bridge: 发现设备 rssi=\(RSSI)，连接中")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        NSLog("[zcode-pet] device bridge: 连接失败 \(error?.localizedDescription ?? "nil")，退避重扫")
        self.peripheral = nil; txChar = nil; rxChar = nil
        link.disconnected(now: Date().timeIntervalSince1970)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.txUUID, Self.rxUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil,
              let tx = service.characteristics?.first(where: { $0.uuid == Self.txUUID }),
              let rx = service.characteristics?.first(where: { $0.uuid == Self.rxUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        txChar = tx
        rxChar = rx
        peripheral.setNotifyValue(true, for: tx)              // 订阅成功（回调）= online
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        if error == nil, characteristic.isNotifying {
            link.subscribed(now: Date().timeIntervalSince1970)
            NSLog("[zcode-pet] device bridge: TX 已订阅 → online")
            sendTick()                                        // 连上立刻补一帧，不等 2s 周期
        } else {
            NSLog("[zcode-pet] device bridge: 订阅丢失 \(error?.localizedDescription ?? "nil")")
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        ingest(data: data, now: Date().timeIntervalSince1970)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // 外设服务表变更（重刷固件等）：断开走完整重发现路径
        central?.cancelPeripheralConnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        NSLog("[zcode-pet] device bridge: 断开（\(error?.localizedDescription ?? "正常")），退避重扫")
        self.peripheral = nil; txChar = nil; rxChar = nil
        link.disconnected(now: Date().timeIntervalSince1970)
    }
}

// MARK: - --bridge-selftest（无 GUI / 无网络 / 无设备 / 不创建 CBCentralManager）

/// 伪造状态序列断言协议编码、链路状态机与文案同步；stringsPath 给出时
/// 额外断言 device_strings.txt 的 # sync: 区与桌面 update() 文案逐条一致。
func runBridgeSelfTest(stringsPath: String?) -> Int32 {
    print("== zcode-pet device bridge self-test ==")
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
    let json = DeviceBridge.statusJSON(seq: 7, state: s3, tsMs: 1_700_000_000_000)
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
        let noN = DeviceBridge.statusJSON(seq: 8, state: s1, tsMs: 0)
        let o2 = noN.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        check("n 缺省不出现（可选字段）", o2?["n"] == nil)
    }

    // ---- D. hello / ack / read 解析 ----
    print("[D] 消息解析")
    let hello = Data("{\"v\":1,\"t\":\"hello\",\"name\":\"zcode-pet\",\"fw\":\"1.0.0\"}".utf8)
    let read = Data("{\"v\":1,\"t\":\"read\"}".utf8)
    let ack = Data("{\"v\":1,\"t\":\"ack\",\"seq\":7}".utf8)
    let garbage = Data("{\"v\":2,\"t\":\"hello\"}".utf8)
    check("hello 解析", DeviceBridge.isHello(hello))
    check("read 解析", DeviceBridge.isRead(read))
    check("ack seq 解析", DeviceBridge.ackSeq(ack) == 7)
    check("版本不符拒绝", !DeviceBridge.isHello(garbage) && DeviceBridge.ackSeq(garbage) == nil)

    // ---- E. BLE 链路状态机（注入时钟；订阅→online、断开→offline+退避、10s 看门狗） ----
    print("[E] BLE 链路状态机")
    var link = DeviceLink()
    var action = link.tick(now: 0)
    check("idle 无动作", action == .none && link.phase == .idle)
    link.scanStarted(now: 0)
    check("开始扫描", link.phase == .scanning)
    link.discovered(now: 0.5)
    check("发现设备 → connecting", link.phase == .connecting)
    link.subscribed(now: 1.0)
    check("订阅成功 → online + 退避清零", link.phase == .online && link.rescanAttempt == 0)
    link.packet(now: 6.0)
    action = link.tick(now: 15.9)
    check("看门狗内（<10s）保持 online", action == .none && link.phase == .online)
    action = link.tick(now: 16.1)
    check("10s 无设备包 → 判死请求断开", action == .dropPeer && link.phase == .offline)
    check("判死即按退避表排队（0s 立即）", link.nextScanAt == 16.1 && link.rescanAttempt == 1)
    link.disconnected(now: 16.1)
    check("迟到断开回调幂等（不改退避）", link.nextScanAt == 16.1 && link.rescanAttempt == 1)
    action = link.tick(now: 16.2)
    check("退避到期 → 重扫", action == .scan)
    link.scanStarted(now: 16.2)
    link.discovered(now: 16.3)
    link.disconnected(now: 17.0)                          // connect 后未订阅即失败
    check("连续第二次失败 → 退避 1s", link.nextScanAt == 18.0 && link.rescanAttempt == 2)
    link.disconnected(now: 17.5)
    check("断开重入幂等（不改退避）", link.nextScanAt == 18.0 && link.rescanAttempt == 2)
    action = link.tick(now: 17.9)
    check("退避未到 → 无动作", action == .none)
    action = link.tick(now: 18.1)
    check("退避到期 → 重扫", action == .scan)
    link.scanStarted(now: 18.1)
    link.discovered(now: 18.2)
    link.subscribed(now: 18.5)
    check("订阅成功 → 退避计数清零", link.rescanAttempt == 0 && link.phase == .online)
    link.disconnected(now: 19.0)
    check("健康链路后的断开重新从 0s 起退", link.nextScanAt == 19.0 && link.rescanAttempt == 1)

    // ingest 全链路：read 回调 + 看门狗喂狗
    let b = DeviceBridge()
    var readCount = 0
    b.onRead = { readCount += 1 }
    let t0: TimeInterval = 1_000_000
    b.link.scanStarted(now: t0)
    b.link.subscribed(now: t0)
    b.ingest(data: read, now: t0 + 1)
    check("read → 已读回调", readCount == 1)
    b.ingest(data: hello, now: t0 + 5)
    b.ingest(data: ack, now: t0 + 9)
    check("hello/ack 喂看门狗", b.link.tick(now: t0 + 18.9) == .none)
    check("10s 无包 → 判死", b.link.tick(now: t0 + 19.1) == .dropPeer)
    check("offline tooltip 指路系统设置", DeviceBridge().tooltip.contains("隐私") ||
          DeviceBridge().tooltip.contains("上电") || DeviceBridge().tooltip.contains("搜索"))
    check("UUID 三常量形状", DeviceBridge.serviceUUID.uuidString == "5A1C0001-7BCD-4E0F-9A2B-3D5E6F8091A2" &&
          DeviceBridge.txUUID.uuidString == "5A1C0002-7BCD-4E0F-9A2B-3D5E6F8091A2" &&
          DeviceBridge.rxUUID.uuidString == "5A1C0003-7BCD-4E0F-9A2B-3D5E6F8091A2")

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
//   12 = 等待 Mac 连接…
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
