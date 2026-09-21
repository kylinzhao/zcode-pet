// zcode-pet-daemon — ZCode 桌面宠物守护进程
//
// v0.3 数据模型修正（实测推翻 v0.1 假设）：
//   · task_status='running' 只在任务首轮为真——后续轮开始不会翻回 running，DB 不能当"执行中"信号；
//     执行中 = hook turn_start/turn_end 事件（lastStart>lastEnd），DB running 仅作首轮兜底。
//   · 每轮结束 DB 会 bump updated_at 并置 completed/error——完成检测 = turn_end 事件
//     （延迟 4s 确认最终状态）或"忙碌会话的 updated_at bump"，双路径 + 冷却去重。
//   · 未读 = unread_at IS NOT NULL（live 标记；last_unread_at 是永久历史时间戳，v0.2 误用导致 156）。
// v0.3 交互修复：宠物可拖动（hitTest 修正：标签不再吞事件）+ 位置持久化。
// v0.2：点宠物回 ZCode；菜单栏 📬M 未读；UN 可点击通知 → --open-workspace 直达工作区。
// v0.4 跳转修正：zcode://workspace/open 深链会被 ZCode 无条件弹「打开外部链接」确认框
//     （每次点完成任务都弹，非信任问题）；改 spawn ZCode 二进制 --open-workspace 参数，全程无弹窗。
//
// 构建：bash scripts/install.sh（编译进 .app bundle + ad-hoc 签名）；自检：--test。

import AppKit
import UserNotifications
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Config

struct PetConfig {
    var dbPath: String
    var pollInterval: TimeInterval
    var notifyCooldown: TimeInterval      // 同一 sessionId 完成事件的去重窗口（双路径触发用）
    var allClearMinSeconds: TimeInterval  // 归零弹窗只对跑过这么久的任务触发
    var busyStaleSeconds: TimeInterval    // 看门狗：忙碌会话超过此时长无事件则静默丢弃
    var confirmDelay: TimeInterval        // turn_end 后等 DB 落库的确认延迟
    var zcodeAppBundleId: String

    static let dataDir = NSHomeDirectory() + "/.zcode-pet"

    static func load() -> PetConfig {
        var c = PetConfig(
            dbPath: NSHomeDirectory() + "/.zcode/v2/tasks-index.sqlite",
            pollInterval: 2.0,
            notifyCooldown: 10.0,
            allClearMinSeconds: 120.0,
            busyStaleSeconds: 2 * 3600,
            confirmDelay: 4.0,
            zcodeAppBundleId: "dev.zcode.app"
        )
        let url = URL(fileURLWithPath: dataDir + "/config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return c }
        if let v = obj["dbPath"] as? String { c.dbPath = v }
        if let v = obj["pollInterval"] as? Double, v >= 0.5 { c.pollInterval = v }
        if let v = obj["notifyCooldown"] as? Double { c.notifyCooldown = v }
        if let v = obj["allClearMinSeconds"] as? Double { c.allClearMinSeconds = v }
        if let v = obj["busyStaleSeconds"] as? Double { c.busyStaleSeconds = v }
        if let v = obj["zcodeAppBundleId"] as? String { c.zcodeAppBundleId = v }
        return c
    }
}

// MARK: - Task store (read-only SQLite)

struct TaskRow {
    let id: String
    let title: String
    let workspacePath: String
    let status: String
    let updatedAtMs: Double
    let unreadAtMs: Double   // <0 = 无未读标记
}

final class TaskStore {
    private var db: OpaquePointer?

    init?(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h = handle else {
            return nil
        }
        db = h
    }
    deinit { if let db { sqlite3_close(db) } }

    /// 全部未归档任务（200 行量级，一次拉全做快照 diff）
    func allTasks() -> [TaskRow] {
        let sql = """
        SELECT task_id, COALESCE(workspace_path,''), title, task_status, updated_at, COALESCE(unread_at,-1)
        FROM tasks WHERE COALESCE(archived,0)=0 AND COALESCE(deleted,0)=0
        """
        var out: [TaskRow] = []
        guard let db else { return out }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let c = { (n: Int32) in sqlite3_column_text(stmt, n).map { String(cString: $0) } ?? "" }
            out.append(TaskRow(id: c(0), title: c(2), workspacePath: c(1), status: c(3),
                               updatedAtMs: (c(4) as NSString).doubleValue,
                               unreadAtMs: (c(5) as NSString).doubleValue))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Persisted state

struct PetState {
    var firstSeen: [String: Double] = [:]    // 会话进入执行中的时刻（算时长）
    var lastNotified: [String: Double] = [:] // 完成事件冷却
    var muteUntil: Double = 0
    var petOrigin: [Double]?                 // 宠物窗口位置持久化
    var skinId: String?                      // 宠物造型

    static func path() -> String { PetConfig.dataDir + "/state.json" }

    static func load() -> PetState {
        var s = PetState()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path())),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return s }
        if let v = obj["firstSeen"] as? [String: Double] { s.firstSeen = v }
        if let v = obj["lastNotified"] as? [String: Double] { s.lastNotified = v }
        if let v = obj["muteUntil"] as? Double { s.muteUntil = v }
        if let v = obj["petOrigin"] as? [Double], v.count == 2 { s.petOrigin = v }
        if let v = obj["skinId"] as? String { s.skinId = v }
        return s
    }

    func save() {
        func bound(_ d: [String: Double]) -> [String: Double] {
            d.count <= 200 ? d : Dictionary(d.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        var obj: [String: Any] = ["firstSeen": bound(firstSeen), "lastNotified": bound(lastNotified), "muteUntil": muteUntil]
        if let petOrigin { obj["petOrigin"] = petOrigin }
        if let skinId { obj["skinId"] = skinId }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            _ = try? data.write(to: URL(fileURLWithPath: PetState.path()))
        }
    }
}

// MARK: - Helpers

enum PetMode { case idle, working, celebrate, error }

// MARK: - 宠物造型（emoji 皮肤）

struct PetSkin {
    let id: String
    let name: String
    let idle: String, working: String, celebrate: String, error: String

    func emoji(for mode: PetMode) -> String {
        switch mode {
        case .idle: return idle
        case .working: return working
        case .celebrate: return celebrate
        case .error: return error
        }
    }
}

let petSkins: [PetSkin] = [
    .init(id: "cat", name: "橘猫", idle: "😺", working: "😸", celebrate: "🎉", error: "😿"),
    .init(id: "blackcat", name: "黑猫", idle: "🐈‍⬛", working: "🐈‍⬛", celebrate: "🎉", error: "😿"),
    .init(id: "dog", name: "小狗", idle: "🐶", working: "🐕", celebrate: "🎉", error: "🥺"),
    .init(id: "panda", name: "熊猫", idle: "🐼", working: "🐼", celebrate: "🎉", error: "😖"),
    .init(id: "fox", name: "小狐狸", idle: "🦊", working: "🦊", celebrate: "🎉", error: "🫠"),
    .init(id: "penguin", name: "企鹅", idle: "🐧", working: "🐧", celebrate: "🎉", error: "😵"),
    .init(id: "chick", name: "小黄鸭", idle: "🐤", working: "🐥", celebrate: "🎉", error: "😵‍💫"),
    .init(id: "frog", name: "青蛙", idle: "🐸", working: "🐸", celebrate: "🎉", error: "😵"),
    .init(id: "trex", name: "恐龙", idle: "🦖", working: "🦕", celebrate: "🎉", error: "😵"),
    .init(id: "unicorn", name: "独角兽", idle: "🦄", working: "🦄", celebrate: "🎉", error: "😵"),
    .init(id: "robot", name: "机器人", idle: "🤖", working: "🤖", celebrate: "🎉", error: "👾"),
    .init(id: "ghost", name: "幽灵", idle: "👻", working: "👻", celebrate: "🎉", error: "💀"),
    .init(id: "rocket", name: "火箭", idle: "🚀", working: "🛸", celebrate: "🎉", error: "💥"),
    .init(id: "potato", name: "土豆", idle: "🥔", working: "🍟", celebrate: "🎉", error: "🫠"),
    .init(id: "flame", name: "小火苗", idle: "🔥", working: "🔥", celebrate: "🎉", error: "💧"),
]

func currentSkin() -> PetSkin {
    let id = PetState.load().skinId
    return petSkins.first { $0.id == id } ?? petSkins[0]
}

func now() -> Double { Date().timeIntervalSince1970 }

func shortTitle(_ s: String, _ n: Int = 28) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count <= n ? trimmed : String(trimmed.prefix(n - 1)) + "…"
}

func durationText(_ d: TimeInterval) -> String {
    let m = Int(d) / 60, s = Int(d) % 60
    return m > 0 ? "跑了 \(m) 分 \(s) 秒" : "跑了 \(s) 秒"
}

// MARK: - Alert panel（必须点掉的二级弹窗；自有浮动窗，不抢键盘焦点）

final class PetAlertController {
    static let shared = PetAlertController()
    private var panel: NSPanel?

    func show(kind: Kind, title: String, body: String) {
        panel?.orderOut(nil)
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.96).cgColor
        container.layer?.borderWidth = 2
        container.layer?.borderColor = (kind == .error ? NSColor.systemRed : NSColor.systemGreen).withAlphaComponent(0.85).cgColor

        let emoji = NSTextField(labelWithString: kind == .error ? "😿" : "🎉")
        emoji.font = .systemFont(ofSize: 44)
        emoji.alignment = .center
        emoji.frame = NSRect(x: 14, y: 40, width: 72, height: 66)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .boldSystemFont(ofSize: 15)
        titleField.textColor = kind == .error ? NSColor.systemRed : NSColor.systemGreen
        titleField.frame = NSRect(x: 96, y: 96, width: 300, height: 20)

        let bodyField = NSTextField(labelWithString: body)
        bodyField.font = .systemFont(ofSize: 12.5)
        bodyField.textColor = .white
        bodyField.lineBreakMode = .byTruncatingTail
        bodyField.frame = NSRect(x: 96, y: 62, width: 300, height: 34)

        let button = NSButton(title: "知道了", target: self, action: #selector(dismiss))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: 320, y: 16, width: 84, height: 30)

        container.addSubview(emoji)
        container.addSubview(titleField)
        container.addSubview(bodyField)
        container.addSubview(button)
        p.contentView = container
        p.setContentSize(container.bounds.size)

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.midX - 210, y: vf.midY + 40))
        }
        p.orderFrontRegardless()
        panel = p
        NSSound(named: kind == .error ? .init("Basso") : .init("Hero"))?.play()
    }

    @objc private func dismiss() { panel?.orderOut(nil); panel = nil }

    enum Kind { case error, allClear }
}

// MARK: - Pet panel（悬浮宠物：点击回 ZCode，拖动移动且位置记忆）

final class PetPanelController {
    private var panel: NSPanel!
    private var emojiField: NSTextField!
    private var captionField: NSTextField!
    private var baseOrigin: NSPoint = .zero
    private var phase: Double = 0
    private var dragging = false

    static let size = NSSize(width: 148, height: 158)

    init(savedOrigin: NSPoint?, onClick: @escaping () -> Void, onDragEnd: @escaping (NSPoint) -> Void) {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: PetPanelController.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let container = DragView(frame: NSRect(origin: .zero, size: PetPanelController.size))
        container.onClick = onClick
        container.onDragBegin = { [weak self] in self?.dragging = true }
        container.onDragEnd = { [weak self] _ in
            // 关键：松手后把动画基准点更新到落点，否则动画把窗口弹回原位（拖拽失效的根因）
            guard let self else { return }
            self.dragging = false
            self.baseOrigin = self.panel.frame.origin
            onDragEnd(self.baseOrigin)
        }
        container.wantsLayer = true
        container.layer?.cornerRadius = 26
        container.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.72).cgColor

        emojiField = NSTextField(labelWithString: "😺")
        emojiField.font = .systemFont(ofSize: 60)
        emojiField.alignment = .center
        emojiField.frame = NSRect(x: 4, y: 62, width: 140, height: 82)

        captionField = NSTextField(labelWithString: "启动中…")
        captionField.font = .systemFont(ofSize: 12.5)
        captionField.textColor = NSColor(white: 1.0, alpha: 0.92)
        captionField.alignment = .center
        captionField.lineBreakMode = .byTruncatingTail
        captionField.frame = NSRect(x: 10, y: 28, width: 128, height: 30)

        container.addSubview(emojiField)
        container.addSubview(captionField)
        p.contentView = container

        // 恢复保存的位置（clamp 到当前屏幕），否则右下角默认
        baseOrigin = NSPoint(x: NSScreen.main?.visibleFrame.maxX ?? 1200 - PetPanelController.size.width - 24,
                             y: (NSScreen.main?.visibleFrame.minY ?? 200) + 28)
        if let origin = savedOrigin, let vf = NSScreen.main?.visibleFrame {
            let x = min(max(origin.x, vf.minX), vf.maxX - PetPanelController.size.width)
            let y = min(max(origin.y, vf.minY), vf.maxY - PetPanelController.size.height)
            baseOrigin = NSPoint(x: x, y: y)
        }
        p.setFrameOrigin(baseOrigin)
        p.orderFrontRegardless()
        panel = p
    }

    func update(mode: PetMode, emoji: String, runningCount: Int, unreadCount: Int) {
        emojiField.stringValue = emoji
        switch mode {
        case .idle:
            captionField.stringValue = unreadCount > 0 ? "休息中 💤 · \(unreadCount) 未读" : "休息中 💤"
        case .working:
            captionField.stringValue = runningCount > 0 ? "\(runningCount) 个任务执行中…" : "执行中…"
        case .celebrate:
            captionField.stringValue = "任务完成！"
        case .error:
            captionField.stringValue = "任务出错了 ⚠️"
        }
    }

    /// 12fps 呼吸/跳动动画（拖拽中暂停——否则每 83ms 把窗口重置回 baseOrigin，拖拽失效）
    func tick(mode: PetMode) {
        guard panel != nil, !dragging else { return }
        phase += 1.0 / 12.0
        var dy: CGFloat = 0
        switch mode {
        case .working: dy = CGFloat(sin(phase * 2 * .pi * 0.8)) * 4
        case .celebrate: dy = abs(CGFloat(sin(phase * 2 * .pi * 1.6))) * -12
        case .error: dy = CGFloat(sin(phase * 2 * .pi * 6.0)) * 2
        case .idle: dy = CGFloat(sin(phase * 2 * .pi * 0.15)) * 2
        }
        panel.setFrameOrigin(NSPoint(x: baseOrigin.x, y: baseOrigin.y + dy))
    }
}

/// 无边框窗拖拽/点击：手动事件跟踪循环（performDrag 在 nonactivating borderless panel 上
/// 行为不稳，且会被动画定时器打架）；位移 <4px 判定为点击。
/// hitTest 返回 self——否则 NSTextField 标签会吞掉鼠标事件。
final class DragView: NSView {
    var onClick: (() -> Void)?
    var onDragBegin: (() -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// 非激活窗口上的首次点击也直接生效（不先"激活窗口"）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false

        while true {
            guard let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if e.type == .leftMouseUp { break }
            let cur = NSEvent.mouseLocation
            let dx = cur.x - startMouse.x
            let dy = cur.y - startMouse.y
            if !moved && (abs(dx) > 3 || abs(dy) > 3) {
                moved = true
                onDragBegin?()
            }
            if moved {
                window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            }
        }

        if moved {
            onDragEnd?(window.frame.origin)
        } else {
            onClick?()
        }
    }
    override func draw(_ dirtyRect: NSRect) {}
}

// MARK: - Event tail（hook 事件文件——执行中状态的权威来源）

final class EventTail {
    private let path: String
    private var offset: UInt64 = 0
    private(set) var stopHookLastAt: Double = 0

    struct Event { let type: String; let session: String; let ts: Double }

    init(path: String) {
        self.path = path
        if let attr = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attr[.size] as? NSNumber { offset = size.uint64Value }
    }

    /// 启动回放：解析全部历史事件，返回窗口内的（用于重建忙碌状态——
    /// 守护进程重启会丢内存状态，而正在执行的轮的 turn_start 已写进文件，EOF 追读看不到）。
    /// offset 已在 EOF，回放的事件不会被 poll() 重复消费。
    func replay(window: TimeInterval) -> [Event] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let cutoff = (now() - window) * 1000
        var events: [Event] = []
        for line in text.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let ts = obj["ts"] as? Double ?? 0
            guard ts > cutoff else { continue }
            let e = Event(type: obj["type"] as? String ?? "",
                          session: obj["session"] as? String ?? "",
                          ts: ts)
            if e.type == "turn_end" { stopHookLastAt = max(stopHookLastAt, ts / 1000) }
            events.append(e)
        }
        return events
    }

    func poll() -> [Event] {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attr[.size] as? NSNumber else { return [] }
        let total = size.uint64Value
        guard total > offset else { if total < offset { offset = total }; return [] }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        _ = try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(total - offset))) ?? Data()
        offset = total
        var events: [Event] = []
        for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let e = Event(type: obj["type"] as? String ?? "",
                          session: obj["session"] as? String ?? "",
                          ts: obj["ts"] as? Double ?? 0)
            if e.type == "turn_end" { stopHookLastAt = max(stopHookLastAt, e.ts > 1e12 ? e.ts / 1000 : e.ts) }
            events.append(e)
        }
        return events
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = PetConfig.load()
    var state = PetState.load()
    let store: TaskStore?
    var skin: PetSkin = currentSkin()

    private var statusItem: NSStatusItem!
    private var pet: PetPanelController!
    private var eventTail: EventTail!

    // hook 事件侧的回合跟踪（秒）
    private var lastStart: [String: Double] = [:]
    private var lastEnd: [String: Double] = [:]
    // 完成确认：turn_end 后延迟查 DB（值 = 到点时刻）
    private var pendingChecks: [String: Double] = [:]
    // DB 快照
    private var prevRows: [String: TaskRow] = [:]
    // UI 缓存
    private var lastRunning: [(title: String, id: String, ws: String)] = []
    private var lastUnread: [TaskRow] = []

    private var mode: PetMode = .idle
    private var modeExpiry: Double = 0
    private var firstPoll = true
    private var lastStateSave = 0.0

    override init() {
        store = TaskStore(path: PetConfig.load().dbPath)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let saved = state.petOrigin.map { NSPoint(x: CGFloat($0[0]), y: CGFloat($0[1])) }
        pet = PetPanelController(savedOrigin: saved,
                                 onClick: { [weak self] in self?.jumpToZCode(workspacePath: nil) },
                                 onDragEnd: { [weak self] origin in
                                     self?.state.petOrigin = [Double(origin.x), Double(origin.y)]
                                     self?.state.save()
                                 })
        eventTail = EventTail(path: PetConfig.dataDir + "/events.jsonl")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"

        rebuildMenu(running: [], unread: [])

        // 重建重启前的忙碌状态：正在执行的轮的 turn_start 已在事件文件里，
        // EOF 追读看不到，必须回放（覆盖重启/开机/重登录场景）
        apply(events: eventTail.replay(window: config.busyStaleSeconds), replayed: true)

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("[zcode-pet] notification auth granted=\(granted) err=\(String(describing: error))")
        }

        Timer.scheduledTimer(withTimeInterval: config.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.drainEvents() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pet.tick(mode: self.currentMode())
        }
    }

    func applicationWillTerminate(_ notification: Notification) { state.save() }

    // MARK: hook 事件 → 回合状态机

    private func drainEvents() {
        apply(events: eventTail.poll(), replayed: false)
    }

    private func apply(events: [EventTail.Event], replayed: Bool) {
        let ts = now()
        for e in events {
            let eTs = e.ts > 1e12 ? e.ts / 1000 : e.ts   // 事件文件里是毫秒
            switch e.type {
            case "turn_start" where !e.session.isEmpty:
                lastStart[e.session] = eTs
                lastEnd[e.session] = nil
                pendingChecks[e.session] = nil
                if state.firstSeen[e.session] == nil { state.firstSeen[e.session] = eTs }
            case "turn_end" where !e.session.isEmpty:
                lastEnd[e.session] = eTs
                if replayed && ts - eTs >= 10 {
                    // 守护进程停机期间就已结束的轮：不补发通知，也不留卡死的忙碌状态
                    lastStart[e.session] = nil
                    pendingChecks[e.session] = nil
                    state.firstSeen[e.session] = nil
                } else {
                    pendingChecks[e.session] = eTs + config.confirmDelay
                }
            default:
                break
            }
        }
    }

    /// 执行中 = 本轮 turn_start 之后尚未完成确认（turn_end 只调度确认，不清忙碌——
    /// 完成由 DB 状态确认，避免 turn_end→新 turn_start 的排队间隙误判空闲）
    private func isBusy(_ s: String) -> Bool { lastStart[s] != nil }

    private var busyIds: [String] { lastStart.keys.filter { isBusy($0) } }

    // MARK: 轮询主干

    private func poll() {
        guard let store else {
            pet.update(mode: .idle, emoji: skin.emoji(for: .idle), runningCount: 0, unreadCount: 0)
            statusItem.button?.title = "🐾"
            return
        }
        let rows = store.allTasks()
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let ts = now()

        // 看门狗：Stop hook 丢失/轮被取消导致卡死的忙碌会话，超时静默清除
        for (s, startTs) in lastStart where ts - startTs > config.busyStaleSeconds {
            lastStart[s] = nil; lastEnd[s] = nil; pendingChecks[s] = nil
            state.firstSeen[s] = nil
            NSLog("[zcode-pet] watchdog dropped stale busy session \(s)")
        }

        // 执行中集合 = hook 忙碌 ∪ DB running（首轮兜底；插件装好后新会话都走 hook）
        var displayIds = Set(busyIds)
        displayIds.formUnion(byId.filter { $0.value.status == "running" }.keys)
        for id in displayIds where state.firstSeen[id] == nil { state.firstSeen[id] = ts }

        if firstPoll {
            firstPoll = false
            prevRows = byId
            updateUI(displayIds: displayIds, byId: byId)
            return
        }

        var sawError = false
        var completions: [(id: String, title: String)] = []
        var longestRun: TimeInterval = 0

        // 完成检测（双路径，均不依赖 updated_at——点击任务列表会 bump 它，曾导致误弹窗）：
        //  A 首轮翻转：prev=DB running → now terminal
        //  B turn_end 延迟确认（4s 后查 DB 终态；Stop hook 实测可靠触发）
        var finishedIds = Set<String>()
        for (id, prev) in prevRows where prev.status == "running" {
            if let row = byId[id], row.status == "completed" || row.status == "error" {
                finishedIds.insert(id)
                handleCompletion(row: row, byId: byId, ts: ts,
                                 completions: &completions, sawError: &sawError, longestRun: &longestRun)
            }
        }
        for (id, dueAt) in pendingChecks where dueAt <= ts {
            guard let row = byId[id], lastStart[id] != nil, !finishedIds.contains(id) else {
                if dueAt <= ts { pendingChecks[id] = nil }
                continue
            }
            if row.status == "completed" || row.status == "error" {
                pendingChecks[id] = nil
                finishedIds.insert(id)
                handleCompletion(row: row, byId: byId, ts: ts,
                                 completions: &completions, sawError: &sawError, longestRun: &longestRun)
            } else if ts - (lastEnd[id] ?? ts) < 12 {
                pendingChecks[id] = ts + 3   // DB 落库最多延迟几秒，重试确认
            } else {
                // 状态迟迟不落：清忙碌不通知（可能是取消的轮）
                pendingChecks[id] = nil
                clearBusy(id)
            }
        }

        if sawError {
            mode = .error; modeExpiry = ts + 5
        } else if !completions.isEmpty {
            mode = .celebrate; modeExpiry = ts + 5
        }

        // 全部归零：只对跑得够久的任务弹二级庆祝（短问答回合不配模态）
        if !completions.isEmpty || sawError {
            let stillBusy = displayIds.subtracting(finishedIds).contains { byId[$0]?.status == "running" || isBusy($0) }
            if !stillBusy && longestRun >= config.allClearMinSeconds {
                tier2(kind: .allClear, taskTitle: completions.last?.title ?? "全部任务", duration: longestRun)
            }
        }

        prevRows = byId
        updateUI(displayIds: displayIds.subtracting(finishedIds), byId: byId)
        scheduleStateSave()
    }

    private func handleCompletion(row: TaskRow, byId: [String: TaskRow], ts: Double,
                                  completions: inout [(id: String, title: String)],
                                  sawError: inout Bool, longestRun: inout TimeInterval) {
        let duration = ts - (state.firstSeen[row.id] ?? ts)
        longestRun = max(longestRun, duration)
        clearBusy(row.id)

        // 双路径去重：冷却窗口内同一会话只提醒一次
        if let last = state.lastNotified[row.id], ts - last < config.notifyCooldown { return }
        state.lastNotified[row.id] = ts

        let title = shortTitle(row.title.isEmpty ? "（无标题）" : row.title)
        switch row.status {
        case "error":
            sawError = true
            postNotification(taskId: row.id, title: "😿 任务出错", body: title, sound: "Basso", workspacePath: row.workspacePath)
            tier2(kind: .error, taskTitle: title, duration: duration)
        default:
            completions.append((row.id, title))
            postNotification(taskId: row.id, title: "🐾 任务完成", body: "\(title)（\(durationText(duration))）",
                             sound: "Glass", workspacePath: row.workspacePath)
        }
    }

    private func clearBusy(_ id: String) {
        lastStart[id] = nil; lastEnd[id] = nil; pendingChecks[id] = nil
        state.firstSeen[id] = nil
    }

    // MARK: 即时通知（UN，点击跳转）+ 二级弹窗

    private func postNotification(taskId: String, title: String, body: String, sound: String, workspacePath: String) {
        guard state.muteUntil <= now() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
        content.threadIdentifier = taskId
        content.userInfo = ["taskId": taskId, "workspacePath": workspacePath]
        let request = UNNotificationRequest(identifier: "pet-\(taskId)-\(Int(now()))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func tier2(kind: PetAlertController.Kind, taskTitle: String, duration: TimeInterval) {
        guard state.muteUntil <= now() else { return }
        let minutes = Int(duration) / 60
        let body = minutes > 0 ? "\(taskTitle) · 用时 \(minutes) 分钟" : taskTitle
        let title: String
        switch kind {
        case .error: title = "任务出错了，需要你看一下"
        case .allClear: title = "全部任务完成，等你回来审核 🎉"
        }
        PetAlertController.shared.show(kind: kind, title: title, body: body)
    }

    /// 跳回 ZCode：优先 --open-workspace 命令行直达工作区，否则仅激活应用。
    /// 不用 zcode://workspace/open 深链——主进程对深链无条件弹「是否在 ZCode 中打开此文件夹？」
    /// 确认框（confirmExternalWorkspaceOpen，无信任列表/绕过参数，3.14.0 实测源码）；
    /// 而 --open-workspace 两条路径都不弹窗：冷启动作为启动参数（open-workspace-arg 源免确认），
    /// 热转发经 single-instance additionalData → handleOpenWorkspacePath → renderer 直接打开。
    func jumpToZCode(workspacePath: String?) {
        if let ws = workspacePath, !ws.isEmpty, let exe = zcodeExecutablePath() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            proc.arguments = ["--open-workspace", ws]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            if (try? proc.run()) != nil {
                return   // 已运行的 ZCode 会通过单实例锁把参数转给主进程，本进程随即自行退出
            }
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == config.zcodeAppBundleId && $0.activationPolicy == .regular }) {
            app.activate()
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/ZCode.app"))
        }
    }

    /// 定位 ZCode 可执行文件：运行中实例的 bundle → 按 bundle id 全局解析 → /Applications 兜底
    private func zcodeExecutablePath() -> String? {
        let candidates: [URL?] = [
            NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == config.zcodeAppBundleId && $0.activationPolicy == .regular
            }?.bundleURL,
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.zcodeAppBundleId),
            URL(fileURLWithPath: "/Applications/ZCode.app")
        ]
        for case let bundle? in candidates {
            let exe = bundle.appendingPathComponent("Contents/MacOS/ZCode").path
            if FileManager.default.isExecutableFile(atPath: exe) { return exe }
        }
        return nil
    }

    // MARK: UI

    private func currentMode() -> PetMode {
        let ts = now()
        if modeExpiry > 0 {
            if ts < modeExpiry { return mode }
            modeExpiry = 0
        }
        mode = (lastRunning.isEmpty && busyIds.isEmpty) ? .idle : .working
        return mode
    }

    private func updateUI(displayIds: Set<String>, byId: [String: TaskRow]) {
        let unread = byId.values
            .filter { ($0.status == "completed" || $0.status == "error") && $0.unreadAtMs > 0 }
            .sorted { $0.unreadAtMs > $1.unreadAtMs }
        let running: [(title: String, id: String, ws: String)] = displayIds.map { id in
            let row = byId[id]
            return (row.map { shortTitle($0.title) } ?? "任务 \(id.prefix(12))…", id, row?.workspacePath ?? "")
        }.sorted { $0.title < $1.title }
        lastRunning = running
        lastUnread = Array(unread)

        let m = currentMode()
        pet.update(mode: m, emoji: skin.emoji(for: m), runningCount: running.count, unreadCount: unread.count)
        let base = running.isEmpty ? "🐾" : "🐾 \(running.count)"
        statusItem.button?.title = unread.isEmpty ? base : "\(base) 📬\(unread.count)"
        rebuildMenu(running: running, unread: lastUnread)
    }

    private func rebuildMenu(running: [(title: String, id: String, ws: String)], unread: [TaskRow]) {
        let menu = NSMenu()

        if running.isEmpty {
            menu.addItem(withTitle: "没有执行中的任务", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "执行中（\(running.count)）— 点击跳转", action: nil, keyEquivalent: "")
            for t in running.prefix(8) {
                let item = menu.addItem(withTitle: "  " + t.title,
                                        action: #selector(openUnreadTask(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = t.ws.isEmpty ? nil : t.ws
            }
        }
        menu.addItem(.separator())

        if !unread.isEmpty {
            menu.addItem(withTitle: "完成未读（\(unread.count)）— 点击跳转", action: nil, keyEquivalent: "")
            for t in unread.prefix(10) {
                let prefix = t.status == "error" ? "⚠️ " : "✅ "
                let item = menu.addItem(withTitle: "  " + prefix + shortTitle(t.title),
                                        action: #selector(openUnreadTask(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = t.workspacePath.isEmpty ? nil : t.workspacePath
            }
            menu.addItem(.separator())
        }

        let ts = now()
        let muted = state.muteUntil > ts
        let muteTitle = muted
            ? "恢复提醒（静音中，\(Int((state.muteUntil - ts) / 60) + 1) 分钟后自动恢复）"
            : "静音 30 分钟"
        let muteItem = menu.addItem(withTitle: muteTitle, action: #selector(toggleMute), keyEquivalent: "m")
        muteItem.target = self

        // 宠物造型子菜单
        let skinMenu = NSMenu(title: "宠物造型")
        for s in petSkins {
            let item = NSMenuItem(title: "\(s.idle)  \(s.name)",
                                  action: #selector(selectSkin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            item.state = (s.id == skin.id) ? .on : .off
            skinMenu.addItem(item)
        }
        let skinItem = menu.addItem(withTitle: "宠物造型 \(skin.idle)", action: nil, keyEquivalent: "")
        skinItem.submenu = skinMenu

        if let last = eventTail?.stopHookLastAt, last > 0 {
            let age = Int(ts - last)
            let heart = age < 90 ? "✓ \(age) 秒前" : (age < 3600 ? "⚠ \(age / 60) 分钟前" : "✗ 久未见")
            menu.addItem(withTitle: "Stop hook 心跳：\(heart)", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Stop hook 心跳：✗ 未见", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出宠物", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let s = petSkins.first(where: { $0.id == id }) else { return }
        skin = s
        state.skinId = id
        state.save()
        if let store {
            let rows = store.allTasks()
            let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            updateUI(displayIds: Set(busyIds).union(byId.filter { $0.value.status == "running" }.keys), byId: byId)
        }
    }

    @objc private func openUnreadTask(_ sender: NSMenuItem) {
        jumpToZCode(workspacePath: sender.representedObject as? String)
    }

    @objc private func toggleMute() {
        let ts = now()
        if state.muteUntil > ts { state.muteUntil = 0 } else { state.muteUntil = ts + 30 * 60 }
        state.save()
        if let store {
            let rows = store.allTasks()
            let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            updateUI(displayIds: Set(busyIds).union(byId.filter { $0.value.status == "running" }.keys), byId: byId)
        }
    }

    @objc private func quit() {
        state.save()
        NSApp.terminate(nil)
    }

    private func scheduleStateSave() {
        let ts = now()
        guard ts - lastStateSave > 5 else { return }
        lastStateSave = ts
        state.save()
    }
}

// MARK: - UN 通知回调：点击跳回任务工作区

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let ws = info["workspacePath"] as? String
        jumpToZCode(workspacePath: (ws?.isEmpty ?? true) ? nil : ws)
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - --test 自检（无 GUI）

func runSelfTest() -> Int32 {
    let config = PetConfig.load()
    print("== zcode-pet-daemon self-test ==")
    print("data dir     : \(PetConfig.dataDir)")
    print("db path      : \(config.dbPath)")
    let fm = FileManager.default
    print("db exists    : \(fm.fileExists(atPath: config.dbPath))")

    guard let store = TaskStore(path: config.dbPath) else {
        print("❌ TaskStore 打开失败"); return 1
    }
    let rows = store.allTasks()
    let running = rows.filter { $0.status == "running" }
    let unread = rows.filter { ($0.status == "completed" || $0.status == "error") && $0.unreadAtMs > 0 }
    print("DB running   : \(running.count)（仅首轮可信，执行中以 hook 为准）")
    for t in running.prefix(5) { print("  - [\(t.id)] \(shortTitle(t.title, 50))") }
    print("未读已完成    : \(unread.count)（unread_at 语义）")
    for t in unread.prefix(5) { print("  - [\(t.status)] \(shortTitle(t.title, 50)) → \(t.workspacePath)") }

    let eventsPath = PetConfig.dataDir + "/events.jsonl"
    print("events file  : \(eventsPath) (\(fm.fileExists(atPath: eventsPath) ? "exists" : "not yet"))")

    let sem = DispatchSemaphore(value: 0)
    var authLine = "unknown"
    UNUserNotificationCenter.current().getNotificationSettings { s in
        switch s.authorizationStatus {
        case .authorized, .provisional: authLine = "granted"
        case .denied: authLine = "DENIED（系统设置 → 通知 → zcode-pet 打开）"
        case .notDetermined: authLine = "notDetermined（守护进程启动后会弹授权提示）"
        @unknown default: break
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 3)
    print("通知授权      : \(authLine)")

    print("== self-test done ==")
    return 0
}

// MARK: - main

if CommandLine.arguments.contains("--test") {
    exit(runSelfTest())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
