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
// v0.4.1 通知图标：横幅图标 = bundle 图标；AppIconManager 渲染 emoji icns 写回 bundle 并重签名，
//     图标跟随宠物皮肤（切换造型即换图标）；install.sh 默认 🐾，启动后对账成当前皮肤。
// v0.5 点击改造（fixes #2）：ZCode 无任务级外部入口（深链只解析 path、单实例转发只认
//     deepLinkUrl/openWorkspacePath 两种意图、无本地端口、AX 树不暴露 Web 内容——3.14.0
//     app.asar 实证），--open-workspace 只能落在工作区的新任务上。改为点击通知/菜单直接弹
//     宠物自己的「任务结果」面板（标题/状态/最后一条助手消息，读 cli db 的 message+part 表），
//     面板内保留「在 ZCode 中打开」按钮；宠物本体点击改纯 activate（不再隐式开工作区）。
// v0.5.3 最小化唤起：activate() 后台调用不恢复最小化窗口，改 open app URL（=Dock 点击）。
// v0.6 宠物点击改任务清单：点宠物在旁边弹 popover 列出执行中/完成未读任务；
//     点执行中项 → --open-workspace 跳该任务的工作区窗口；点未读项 → 任务结果面板。
// v0.7 手绘皮肤：PetSkin 支持可选 art 闭包（NSBezierPath 代码作画，4 种状态各画各的），
//     面板走 NSImageView、通知图标走同一套渲染；新增樱木花道/白兵，恐龙(trex)由 emoji
//     重绘为手绘。--render-art <dir> 可导出全部手绘皮肤的 PNG 自检。
//
// 构建：bash scripts/install.sh（编译进 .app bundle + ad-hoc 签名）；自检：--test。

import AppKit
import UserNotifications
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Config

struct PetConfig {
    var dbPath: String
    var resultDbPath: String             // cli 消息库（任务结果面板取最后一条助手消息）
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
            resultDbPath: NSHomeDirectory() + "/.zcode/cli/db/db.sqlite",
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
        if let v = obj["resultDbPath"] as? String { c.resultDbPath = v }
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

// MARK: - Task result store（cli 消息库：会话最后一条助手消息）

/// 读 ~/.zcode/cli/db/db.sqlite 的 message+part 表。task_id 即 session_id。
/// 选文策略：从新到旧逐条 assistant 消息看；每条里优先取非工具回显的 text part
/// （同条多个取最后一个），整条没有就用它的 reasoning part（最后一步常是工具调用，
/// 总结只在 reasoning 里）；都空才退到更早的助手消息。
final class TaskResultStore {
    private var db: OpaquePointer?

    init?(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h = handle else {
            return nil
        }
        db = h
    }
    deinit { if let db { sqlite3_close(db) } }

    private func query(_ sql: String, _ bind: (OpaquePointer) -> Void = { _ in }) -> [[String: String]] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var rows: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let c = { (n: Int32) in sqlite3_column_text(stmt, n).map { String(cString: $0) } ?? "" }
            rows.append(["id": c(0), "data": c(1)])
        }
        return rows
    }

    func lastAssistantText(sessionId: String) -> String? {
        // 最近 6 条 assistant 消息（时间倒序）
        let messages = query("""
        SELECT id, data FROM message WHERE session_id = ?1
        AND instr(data, '"role":"assistant"') > 0
        ORDER BY time_created DESC, sequence DESC LIMIT 6
        """) { sqlite3_bind_text($0, 1, sessionId, -1, SQLITE_TRANSIENT) }

        for msg in messages {
            var textHit: String?, reasoningHit: String?
            var stmt: OpaquePointer?
            let sql = "SELECT data FROM part WHERE message_id = ?1 ORDER BY sequence"
            guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, msg["id"] ?? "", -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let partData = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(partData.utf8))) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty { continue }
                if type == "text", !text.hasPrefix("**🌐") { textHit = text }
                if type == "reasoning" { reasoningHit = text }
            }
            if let textHit { return textHit }
            if let reasoningHit { return reasoningHit }
        }
        return nil
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

// MARK: - 宠物造型（emoji 皮肤 + 手绘皮肤）

struct PetSkin {
    let id: String
    let name: String
    let glyph: String                      // 菜单里的代表 emoji（手绘皮肤也用 emoji 当小图标）
    let idle: String, working: String, celebrate: String, error: String
    let art: ((PetMode, NSRect) -> Void)?  // 非 nil = 手绘皮肤：面板/通知图标走代码作画，emoji 仅兜底

    init(id: String, name: String, glyph: String? = nil,
         idle: String, working: String, celebrate: String, error: String,
         art: ((PetMode, NSRect) -> Void)? = nil) {
        self.id = id
        self.name = name
        self.glyph = glyph ?? idle
        self.idle = idle
        self.working = working
        self.celebrate = celebrate
        self.error = error
        self.art = art
    }

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
    .init(id: "sakuragi", name: "樱木花道", idle: "🏀", working: "🏀", celebrate: "🎉", error: "😵",
          art: { PetArt.sakuragi($0, in: $1) }),
    .init(id: "blackcat", name: "黑猫", idle: "🐈‍⬛", working: "🐈‍⬛", celebrate: "🎉", error: "😿"),
    .init(id: "dog", name: "小狗", idle: "🐶", working: "🐕", celebrate: "🎉", error: "🥺"),
    .init(id: "panda", name: "熊猫", idle: "🐼", working: "🐼", celebrate: "🎉", error: "😖"),
    .init(id: "fox", name: "小狐狸", idle: "🦊", working: "🦊", celebrate: "🎉", error: "🫠"),
    .init(id: "penguin", name: "企鹅", idle: "🐧", working: "🐧", celebrate: "🎉", error: "😵"),
    .init(id: "chick", name: "小黄鸭", idle: "🐤", working: "🐥", celebrate: "🎉", error: "😵‍💫"),
    .init(id: "frog", name: "青蛙", idle: "🐸", working: "🐸", celebrate: "🎉", error: "😵"),
    .init(id: "trex", name: "恐龙", idle: "🦖", working: "🦕", celebrate: "🎉", error: "😵",
          art: { PetArt.dino($0, in: $1) }),
    .init(id: "trooper", name: "白兵", idle: "🪖", working: "🪖", celebrate: "🎉", error: "😵",
          art: { PetArt.trooper($0, in: $1) }),
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

// MARK: - 手绘宠物（NSBezierPath 代码作画，非 emoji 皮肤）
//
// 画布逻辑坐标 104×68（与宠物面板 art 区域同比例，原点左下），等比缩放居中画进目标 rect。
// 每个角色按 PetMode 画不同姿势/表情。--render-art <dir> 可导出全部 PNG 肉眼自检。

enum PetArt {
    static let W: CGFloat = 104
    static let H: CGFloat = 68

    private static let ink = NSColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1)
    private static let white = NSColor.white

    // MARK: 渲染入口

    /// 把 art 闭包按画布坐标等比缩放居中画进 rect
    static func render(art: (PetMode, NSRect) -> Void, mode: PetMode, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let scale = min(rect.width / W, rect.height / H)
        let t = NSAffineTransform()
        t.translateX(by: rect.midX - W * scale / 2, yBy: rect.midY - H * scale / 2)
        t.scaleX(by: scale, yBy: scale)
        t.concat()
        art(mode, NSRect(origin: .zero, size: NSSize(width: W, height: H)))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 2x 位图（Retina 清晰），给面板 NSImageView 用
    static func image(skin: PetSkin, mode: PetMode) -> NSImage {
        let rep = bitmap(skin: skin, mode: mode, scale: 2)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    private static func bitmap(skin: PetSkin, mode: PetMode, scale: CGFloat) -> NSBitmapImageRep {
        let w = W * scale, h = H * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: W, height: H)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        render(art: skin.art!, mode: mode, in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// --render-art：导出全部手绘皮肤的 4 种状态 + 图标效果 PNG，返回失败数
    @discardableResult
    static func exportAll(to dir: String) -> Int32 {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var failures = 0
        for skin in petSkins where skin.art != nil {
            for mode in [PetMode.idle, .working, .celebrate, .error] {
                let png = bitmap(skin: skin, mode: mode, scale: 4).representation(using: .png, properties: [:])
                let path = (dir as NSString).appendingPathComponent("\(skin.id)-\(modeName(mode)).png")
                if let png {
                    do { try png.write(to: URL(fileURLWithPath: path)) } catch { failures += 1 }
                } else { failures += 1 }
            }
            let iconPath = (dir as NSString).appendingPathComponent("\(skin.id)-icon.png")
            if !AppIconManager.renderIconPNG(skin: skin, pixels: 512, to: URL(fileURLWithPath: iconPath)) { failures += 1 }
        }
        print("render-art done → \(dir) (failures: \(failures))")
        return Int32(failures)
    }

    private static func modeName(_ m: PetMode) -> String {
        switch m {
        case .idle: return "idle"
        case .working: return "working"
        case .celebrate: return "celebrate"
        case .error: return "error"
        }
    }

    // MARK: 图元

    private static func fill(_ c: NSColor, _ p: NSBezierPath) { c.setFill(); p.fill() }

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ c: NSColor) {
        fill(c, NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)))
    }

    private static func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c: NSColor) {
        fill(c, NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r))
    }

    private static func poly(_ pts: [NSPoint], _ c: NSColor) {
        guard let first = pts.first else { return }
        let p = NSBezierPath()
        p.move(to: first)
        for q in pts.dropFirst() { p.line(to: q) }
        p.close()
        fill(c, p)
    }

    private static func stroke(_ pts: [NSPoint], _ w: CGFloat, _ c: NSColor) {
        guard let first = pts.first else { return }
        let p = NSBezierPath()
        p.move(to: first)
        for q in pts.dropFirst() { p.line(to: q) }
        c.setStroke()
        p.lineWidth = w
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.stroke()
    }

    /// 二次曲线（控制点同用两次 ≈ quadratic），画笑弧/眉毛
    private static func curve(from: NSPoint, to: NSPoint, ctrl: NSPoint, _ w: CGFloat, _ c: NSColor) {
        let p = NSBezierPath()
        p.move(to: from)
        p.curve(to: to, controlPoint1: ctrl, controlPoint2: ctrl)
        c.setStroke()
        p.lineWidth = w
        p.lineCapStyle = .round
        p.stroke()
    }

    private static func text(_ s: String, _ size: CGFloat, _ c: NSColor, _ cx: CGFloat, _ cy: CGFloat) {
        let str = NSAttributedString(string: s, attributes: [
            .font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: c])
        let b = str.boundingRect(with: NSSize(width: 400, height: 400), options: [.usesLineFragmentOrigin])
        str.draw(at: NSPoint(x: cx - b.width / 2 - b.origin.x, y: cy - b.height / 2 - b.origin.y))
    }

    /// 汗滴（紧张/出错通用）
    private static func sweat(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat = 1) {
        let blue = NSColor(red: 0.40, green: 0.72, blue: 0.98, alpha: 1)
        poly([NSPoint(x: cx - 2.6 * s, y: cy + 1.2 * s), NSPoint(x: cx + 2.6 * s, y: cy + 1.2 * s),
              NSPoint(x: cx, y: cy + 6.6 * s)], blue)
        ellipse(cx, cy, 3.0 * s, 3.4 * s, blue)
    }

    // MARK: 恐龙（手绘 trex：绿皮肤 + 背角刺 + 浅色口鼻）

    static func dino(_ mode: PetMode, in r: NSRect) {
        let green = NSColor(red: 0.33, green: 0.70, blue: 0.36, alpha: 1)
        let darkGreen = NSColor(red: 0.20, green: 0.48, blue: 0.24, alpha: 1)
        let light = NSColor(red: 0.82, green: 0.92, blue: 0.72, alpha: 1)
        let tongue = NSColor(red: 0.88, green: 0.35, blue: 0.40, alpha: 1)

        // 手臂（先画，被头型压住一半，看起来从身后伸出）
        switch mode {
        case .celebrate:
            stroke([NSPoint(x: 22, y: 20), NSPoint(x: 14, y: 37)], 9, green)
            stroke([NSPoint(x: 82, y: 20), NSPoint(x: 90, y: 37)], 9, green)
        case .working:
            stroke([NSPoint(x: 20, y: 18), NSPoint(x: 15, y: 26)], 9, green)
            stroke([NSPoint(x: 80, y: 20), NSPoint(x: 88, y: 34)], 9, green)
        default:
            ellipse(17, 18, 5.5, 8, green)
            ellipse(87, 18, 5.5, 8, green)
        }

        // 头 + 背角刺
        rrect(22, 12, 60, 50, 24, green)
        poly([NSPoint(x: 39, y: 59), NSPoint(x: 46, y: 59), NSPoint(x: 42.5, y: 66)], darkGreen)
        poly([NSPoint(x: 49, y: 61), NSPoint(x: 55, y: 61), NSPoint(x: 52, y: 67)], darkGreen)
        poly([NSPoint(x: 58, y: 59), NSPoint(x: 65, y: 59), NSPoint(x: 61.5, y: 66)], darkGreen)

        // 浅色口鼻 + 鼻孔 + 腮红
        ellipse(52, 22, 22, 12, light)
        ellipse(45.5, 29.5, 1.6, 2, darkGreen)
        ellipse(58.5, 29.5, 1.6, 2, darkGreen)
        ellipse(28, 37, 4, 2.2, light.withAlphaComponent(0.6))
        ellipse(76, 37, 4, 2.2, light.withAlphaComponent(0.6))

        switch mode {
        case .idle:
            for cx in [40.0, 64.0] {
                ellipse(cx, 45, 5.5, 6.2, white)
                ellipse(cx + 0.6, 45.5, 2.5, 2.8, ink)
                ellipse(cx + 1.6, 46.6, 0.9, 0.9, white)
            }
            curve(from: NSPoint(x: 43, y: 22), to: NSPoint(x: 61, y: 22), ctrl: NSPoint(x: 52, y: 17.5), 2.4, darkGreen)
        case .working:
            // 专注：上眼皮压半只眼，瞳孔下移看活
            for cx in [40.0, 64.0] {
                ellipse(cx, 45, 5.5, 6.2, white)
                ellipse(cx + 0.6, 43.8, 2.5, 2.8, ink)
                fill(green, NSBezierPath(rect: NSRect(x: cx - 5.5, y: 47.5, width: 11, height: 5)))
                ellipse(cx, 47.5, 5.5, 1.2, darkGreen)
            }
            stroke([NSPoint(x: 44, y: 20), NSPoint(x: 60, y: 20)], 2.4, darkGreen)
            sweat(84, 46, 0.9)
        case .celebrate:
            // 眯眼笑 ^ ^
            curve(from: NSPoint(x: 35, y: 44), to: NSPoint(x: 45, y: 44), ctrl: NSPoint(x: 40, y: 50), 2.6, ink)
            curve(from: NSPoint(x: 59, y: 44), to: NSPoint(x: 69, y: 44), ctrl: NSPoint(x: 64, y: 50), 2.6, ink)
            rrect(40, 16, 24, 11, 5.5, ink)
            ellipse(52, 17.5, 7, 3.4, tongue)
        case .error:
            for cx in [40.0, 64.0] {
                stroke([NSPoint(x: cx - 4, y: 41.5), NSPoint(x: cx + 4, y: 48.5)], 2.4, ink)
                stroke([NSPoint(x: cx - 4, y: 48.5), NSPoint(x: cx + 4, y: 41.5)], 2.4, ink)
            }
            curve(from: NSPoint(x: 44, y: 22), to: NSPoint(x: 60, y: 22), ctrl: NSPoint(x: 52, y: 26.5), 2.4, darkGreen)
            sweat(85, 47, 1.05)
        }
    }

    // MARK: 樱木花道（灌篮高手 10 号：红发刺头 + 湘北球衣 + 篮球）

    static func sakuragi(_ mode: PetMode, in r: NSRect) {
        let hair = NSColor(red: 0.86, green: 0.23, blue: 0.16, alpha: 1)
        let skinTone = NSColor(red: 1.0, green: 0.87, blue: 0.71, alpha: 1)
        let jersey = NSColor(red: 0.73, green: 0.10, blue: 0.14, alpha: 1)
        let ink2 = NSColor(red: 0.20, green: 0.11, blue: 0.08, alpha: 1)
        let ballColor = NSColor(red: 0.93, green: 0.55, blue: 0.16, alpha: 1)
        let ballSeam = NSColor(red: 0.45, green: 0.22, blue: 0.05, alpha: 1)

        func basketball(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat) {
            ellipse(cx, cy, rad, rad, ballColor)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: cx - rad, y: cy)); p.line(to: NSPoint(x: cx + rad, y: cy))
            p.move(to: NSPoint(x: cx, y: cy - rad)); p.line(to: NSPoint(x: cx, y: cy + rad))
            ballSeam.setStroke(); p.lineWidth = 1.3; p.stroke()
            for side in [-1.0, 1.0] {
                let a = NSBezierPath()
                a.appendArc(withCenter: NSPoint(x: cx + side * rad * 1.55, y: cy), radius: rad * 1.2,
                            startAngle: side < 0 ? -35 : 145, endAngle: side < 0 ? 35 : 215)
                ballSeam.setStroke(); a.lineWidth = 1.3; a.stroke()
            }
        }

        // 篮球 + 手臂（先画，球衣和头压在上面）
        switch mode {
        case .idle:
            basketball(88, 11, 8)
            ellipse(26, 13, 5, 9, skinTone)
            ellipse(78, 13, 5, 9, skinTone)
        case .working:
            basketball(88, 7, 7)
            // 拍球运动线
            stroke([NSPoint(x: 81, y: 18.5), NSPoint(x: 85, y: 20)], 1.6, skinTone)
            stroke([NSPoint(x: 89, y: 17), NSPoint(x: 94, y: 18.5)], 1.6, skinTone)
            ellipse(26, 13, 5, 9, skinTone)
            stroke([NSPoint(x: 74, y: 17), NSPoint(x: 83, y: 9.5)], 7.5, skinTone)
        case .celebrate:
            stroke([NSPoint(x: 27, y: 17), NSPoint(x: 21, y: 33)], 8, skinTone)
            stroke([NSPoint(x: 77, y: 17), NSPoint(x: 83, y: 33)], 8, skinTone)
            basketball(87, 45, 6.5)
        case .error:
            ellipse(26, 13, 5, 9, skinTone)
            ellipse(78, 13, 5, 9, skinTone)
            sweat(80, 46)
        }

        // 球衣（湘北红 + 白肩带 + 10 号）
        rrect(32, 0, 40, 23, 9, jersey)
        rrect(33, 16, 9, 7, 3, white)
        rrect(62, 16, 9, 7, 3, white)
        text("10", 11, white, 52, 8.5)

        // 头
        ellipse(52, 40, 23, 23, skinTone)

        // 头发：标志刺头顶 + M 形发际线
        poly([NSPoint(x: 29, y: 45), NSPoint(x: 27.5, y: 53), NSPoint(x: 33, y: 59),
              NSPoint(x: 37, y: 55.5), NSPoint(x: 42, y: 63), NSPoint(x: 47, y: 57.5),
              NSPoint(x: 52, y: 65), NSPoint(x: 57, y: 57.5), NSPoint(x: 62, y: 63),
              NSPoint(x: 67, y: 55.5), NSPoint(x: 71, y: 59), NSPoint(x: 76.5, y: 53),
              NSPoint(x: 75, y: 45),
              NSPoint(x: 66, y: 47.5), NSPoint(x: 57, y: 47.5), NSPoint(x: 52, y: 43),
              NSPoint(x: 47, y: 47.5), NSPoint(x: 38, y: 47.5)], hair)
        rrect(28.5, 38, 5, 9, 2.5, hair)
        rrect(70.5, 38, 5, 9, 2.5, hair)

        // 眉毛：干劲 = 眉尾高眉心低；出错 = 担忧眉（反转）
        switch mode {
        case .error:
            stroke([NSPoint(x: 37, y: 44), NSPoint(x: 47, y: 46.5)], 2.8, ink2)
            stroke([NSPoint(x: 57, y: 46.5), NSPoint(x: 67, y: 44)], 2.8, ink2)
        default:
            stroke([NSPoint(x: 37, y: 45.5), NSPoint(x: 47, y: 42.5)], 2.8, ink2)
            stroke([NSPoint(x: 57, y: 42.5), NSPoint(x: 67, y: 45.5)], 2.8, ink2)
        }

        // 眼睛
        for (cx, dx) in [(43.0, 0.8), (61.0, -0.8)] {
            ellipse(cx, 35.5, 4.6, 5.4, white)
            ellipse(cx + dx, 35.8, 2.3, 2.7, ink2)
            ellipse(cx + dx + 0.9, 37.0, 0.8, 0.8, white)
        }

        // 嘴
        switch mode {
        case .idle:
            grin(w: 15, h: 7, cy: 27, ink: ink2)
        case .working:
            rrect(44.5, 24.5, 15, 4.5, 2.2, ink2)                       // 咬牙
            stroke([NSPoint(x: 46.5, y: 26.7), NSPoint(x: 57.5, y: 26.7)], 1.4, white)
        case .celebrate:
            grin(w: 19, h: 9, cy: 27, ink: ink2, tongue: true)
        case .error:
            curve(from: NSPoint(x: 45, y: 25), to: NSPoint(x: 59, y: 25), ctrl: NSPoint(x: 52, y: 28.5), 2.4, ink2)
        }
    }

    /// 张嘴大笑（上半直线下弯月形 + 牙 + 可选舌头），樱木专用
    private static func grin(w: CGFloat, h: CGFloat, cy: CGFloat, ink: NSColor, tongue: Bool = false) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 52 - w / 2, y: cy))
        p.curve(to: NSPoint(x: 52 + w / 2, y: cy),
                controlPoint1: NSPoint(x: 52 - w * 0.3, y: cy - h), controlPoint2: NSPoint(x: 52 + w * 0.3, y: cy - h))
        p.close()
        ink.setFill(); p.fill()
        let teeth = NSBezierPath()
        teeth.move(to: NSPoint(x: 52 - w / 2 + 2, y: cy - 0.4))
        teeth.line(to: NSPoint(x: 52 + w / 2 - 2, y: cy - 0.4))
        teeth.line(to: NSPoint(x: 52 + w / 2 - 3.5, y: cy - 2.6))
        teeth.line(to: NSPoint(x: 52 - w / 2 + 3.5, y: cy - 2.6))
        teeth.close()
        white.setFill(); teeth.fill()
        if tongue { ellipse(52, cy - h * 0.55, 4, 2.2, NSColor(red: 0.85, green: 0.35, blue: 0.40, alpha: 1)) }
    }

    // MARK: 星球大战白兵（白盔黑 visor + 皱眉通气管 + 白色装甲）

    static func trooper(_ mode: PetMode, in r: NSRect) {
        let armor = NSColor(calibratedWhite: 0.96, alpha: 1)
        let shade = NSColor(calibratedWhite: 0.78, alpha: 1)
        let visor = NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        let gray = NSColor(calibratedWhite: 0.55, alpha: 1)

        // 手臂（先画）
        switch mode {
        case .celebrate:
            stroke([NSPoint(x: 26, y: 16), NSPoint(x: 20, y: 34)], 8, armor)
            stroke([NSPoint(x: 78, y: 16), NSPoint(x: 84, y: 34)], 8, armor)
        default:
            ellipse(25, 12, 5.5, 9, armor)
            ellipse(79, 12, 5.5, 9, armor)
        }

        // 躯干装甲 + 肩甲 + 腰带
        ellipse(31, 19, 8, 5.5, shade)
        ellipse(73, 19, 8, 5.5, shade)
        rrect(33, 0, 38, 23, 9, armor)
        rrect(33, 2.5, 38, 4, 2, NSColor(calibratedWhite: 0.30, alpha: 1))
        if mode != .working {
            rrect(44, 9, 5, 4.5, 1.2, gray)
            rrect(55, 9, 5, 4.5, 1.2, gray)
        } else {
            // E-11 爆能枪横持胸前（枪身压住胸口细节，白色圆点 = 握枪的手）
            stroke([NSPoint(x: 31, y: 16), NSPoint(x: 45, y: 14)], 6, armor)
            stroke([NSPoint(x: 73, y: 16), NSPoint(x: 59, y: 14)], 6, armor)
            rrect(40, 12.5, 32, 3.5, 1.75, visor)     // 枪身
            rrect(42, 11.5, 12, 5.5, 2, visor)        // 机匣
            rrect(45, 17, 8, 3, 1.5, visor)           // 瞄准镜
            rrect(46, 6.5, 4, 5.5, 1.5, visor)        // 握把
            ellipse(47, 14, 3.6, 3.6, armor)
            ellipse(58, 14, 3.6, 3.6, armor)
        }

        // 头盔：颅顶 + 面甲下缘 + 盔顶中线/眉脊
        ellipse(52, 42, 22, 19, armor)
        ellipse(52, 29, 19.5, 11.5, armor)
        stroke([NSPoint(x: 52, y: 61), NSPoint(x: 52, y: 52.5)], 1.6, shade)
        curve(from: NSPoint(x: 33, y: 45), to: NSPoint(x: 71, y: 45), ctrl: NSPoint(x: 52, y: 52.5), 1.4, shade)

        // 眼睛（visor）
        switch mode {
        case .celebrate:
            curve(from: NSPoint(x: 38.5, y: 41), to: NSPoint(x: 48, y: 41), ctrl: NSPoint(x: 43.2, y: 46.5), 3, visor)
            curve(from: NSPoint(x: 56, y: 41), to: NSPoint(x: 65.5, y: 41), ctrl: NSPoint(x: 60.8, y: 46.5), 3, visor)
            ellipse(22, 50, 2, 2, NSColor(red: 0.95, green: 0.75, blue: 0.20, alpha: 1))
            ellipse(86, 54, 2.2, 2.2, NSColor(red: 0.90, green: 0.35, blue: 0.30, alpha: 1))
            ellipse(52, 66, 1.8, 1.8, NSColor(red: 0.35, green: 0.70, blue: 0.90, alpha: 1))
        case .error:
            ellipse(43.2, 42, 4.6, 5.2, visor)
            ellipse(60.8, 42, 4.6, 5.2, visor)
            // 盔顶裂纹
            stroke([NSPoint(x: 47, y: 57.5), NSPoint(x: 52, y: 54), NSPoint(x: 49, y: 51), NSPoint(x: 54, y: 47.5)], 1.5, gray)
            sweat(77, 50)
        default:
            ellipse(43.2, 42, 4.6, 5.2, visor)
            ellipse(60.8, 42, 4.6, 5.2, visor)
            ellipse(41.8, 43.8, 1.1, 1.1, white)
            ellipse(59.4, 43.8, 1.1, 1.1, white)
        }

        // 标志性皱眉通气管（灰鼻梁条 + 黑色下收梯形）
        rrect(48, 38, 8, 2.2, 1.1, gray)
        poly([NSPoint(x: 46.5, y: 34.5), NSPoint(x: 57.5, y: 34.5), NSPoint(x: 55.5, y: 29), NSPoint(x: 48.5, y: 29)], visor)
        rrect(46, 33.6, 12, 2.6, 1.3, visor)
    }
}

// MARK: - App 图标（跟随宠物皮肤）
//
// 通知横幅图标 = App bundle 图标。切换皮肤时把新 emoji 渲染成 icns 写回自己的 bundle，
// 重新 ad-hoc 签名（改 Resources 会破坏原签名），再刷 usernoted 的图标缓存。
// Resources/AppIcon.skin 记录当前 icns 是哪个皮肤，启动时据此跳过无谓的重打。

enum AppIconManager {
    private static let queue = DispatchQueue(label: "dev.zcode.pet.icon", qos: .utility)
    private static let sizes = [16, 32, 128, 256, 512]

    /// 异步把 bundle 图标换成指定皮肤（已是该皮肤则跳过）
    static func apply(skin: PetSkin) {
        queue.async {
            let bundle = Bundle.main
            guard bundle.bundleIdentifier == "dev.zcode.pet", let res = bundle.resourceURL else { return }
            let marker = res.appendingPathComponent("AppIcon.skin")
            let current = (try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard current != skin.id else { return }
            guard generate(skin: skin, to: res.appendingPathComponent("AppIcon.icns")) else { return }
            try? skin.id.write(to: marker, atomically: true, encoding: .utf8)
            _ = run("/usr/bin/codesign", ["--force", "-s", "-", bundle.bundlePath])
            _ = run("/usr/bin/killall", ["usernoted"])   // 通知横幅的图标缓存
            NSLog("[zcode-pet] app icon swapped to skin \(skin.id)")
        }
    }

    /// emoji → 全尺寸 iconset → iconutil 打包 icns（--gen-icon 命令行也走这里）
    static func generate(emoji: String, to dest: URL) -> Bool {
        generateTo(dest) { size in drawEmoji(emoji, size: size) }
    }

    /// 皮肤 → icns：手绘皮肤画 art，emoji 皮肤画 emoji
    static func generate(skin: PetSkin, to dest: URL) -> Bool {
        guard skin.art != nil else { return generate(emoji: skin.idle, to: dest) }
        return generateTo(dest) { size in drawArt(skin, size: size) }
    }

    /// 图标 PNG 预览（--render-art 自检用）
    static func renderIconPNG(skin: PetSkin, pixels: Int, to url: URL) -> Bool {
        guard skin.art != nil else {
            return writePNG(content: { drawEmoji(skin.idle, size: $0) }, pixels: pixels, to: url)
        }
        return writePNG(content: { drawArt(skin, size: $0) }, pixels: pixels, to: url)
    }

    private static func generateTo(_ dest: URL, content: (CGFloat) -> Void) -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = tmp.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        do { try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true) } catch { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        for s in sizes {
            guard writePNG(content: content, pixels: s, to: iconset.appendingPathComponent("icon_\(s)x\(s).png")),
                  writePNG(content: content, pixels: s * 2, to: iconset.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
            else { return false }
        }
        return run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", dest.path]) == 0
    }

    private static func writePNG(content: (CGFloat) -> Void, pixels: Int, to url: URL) -> Bool {
        let size = CGFloat(pixels)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        // 圆角底 + 暖色渐变（各皮肤共用同一配方，只有内容变）
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: CGSize(width: size, height: size)),
                     xRadius: size * 0.22, yRadius: size * 0.22).addClip()
        let colors = [NSColor(srgbRed: 1.00, green: 0.80, blue: 0.48, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.95, green: 0.55, blue: 0.18, alpha: 1).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
        }
        content(size)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true } catch { return false }
    }

    private static func drawEmoji(_ emoji: String, size: CGFloat) {
        let str = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: size * 0.62)])
        let b = str.boundingRect(with: NSSize(width: size, height: size), options: [.usesLineFragmentOrigin])
        str.draw(at: NSPoint(x: (size - b.width) / 2 - b.origin.x, y: (size - b.height) / 2 - b.origin.y))
    }

    private static func drawArt(_ skin: PetSkin, size: CGFloat) {
        PetArt.render(art: skin.art!, mode: .idle,
                      in: NSRect(x: size * 0.07, y: size * 0.10, width: size * 0.86, height: size * 0.80))
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return nil }
    }
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

// MARK: - 任务结果面板（点击完成/出错任务 → 就地看结果，不再隐式开 ZCode 新任务）

final class TaskResultPanelController {
    static let shared = TaskResultPanelController()
    private var panel: NSPanel?
    private var titleField: NSTextField!
    private var metaField: NSTextField!
    private var emojiField: NSTextField!
    private var textView: NSTextView!
    private var openButton: NSButton!
    private var workspacePath: String?

    func show(title: String, isError: Bool, meta: String, body: String, workspacePath ws: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.show(title: title, isError: isError, meta: meta, body: body, workspacePath: ws) }
            return
        }
        panel?.orderOut(nil)
        workspacePath = ws

        let W: CGFloat = 640, H: CGFloat = 580
        // 直接按目标尺寸创建（.zero+setContentSize 会让窗口保持 0x0——实测坑）
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear

        let container = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.97).cgColor
        container.layer?.borderWidth = 2
        container.layer?.borderColor = (isError ? NSColor.systemRed : NSColor.systemGreen).withAlphaComponent(0.85).cgColor

        emojiField = NSTextField(labelWithString: isError ? "⚠️" : "🎉")
        emojiField.font = .systemFont(ofSize: 34)
        emojiField.alignment = .center
        emojiField.frame = NSRect(x: 16, y: H - 62, width: 56, height: 48)

        titleField = NSTextField(labelWithString: title)
        titleField.font = .boldSystemFont(ofSize: 16)
        titleField.textColor = isError ? NSColor.systemRed : NSColor.systemGreen
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.frame = NSRect(x: 80, y: H - 42, width: W - 100, height: 22)

        metaField = NSTextField(labelWithString: meta)
        metaField.font = .systemFont(ofSize: 12)
        metaField.textColor = NSColor(white: 1.0, alpha: 0.65)
        metaField.lineBreakMode = .byTruncatingTail
        metaField.frame = NSRect(x: 80, y: H - 62, width: W - 100, height: 18)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 66, width: W - 40, height: H - 110))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.6).cgColor
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = NSColor(white: 1.0, alpha: 0.92)
        tv.string = body.isEmpty ? "（这条会话没有可显示的文本结果——点下方按钮去 ZCode 里看）" : body
        scroll.documentView = tv
        textView = tv

        let close = NSButton(title: "关闭", target: self, action: #selector(dismiss))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.frame = NSRect(x: W - 210, y: 18, width: 90, height: 32)
        openButton = NSButton(title: "在 ZCode 中打开", target: self, action: #selector(openInZCode))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.frame = NSRect(x: W - 112, y: 18, width: 92, height: 32)

        container.addSubview(emojiField)
        container.addSubview(titleField)
        container.addSubview(metaField)
        container.addSubview(scroll)
        container.addSubview(close)
        container.addSubview(openButton)
        p.contentView = container
        p.setContentSize(container.bounds.size)

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.midX - W / 2, y: vf.midY - 80))
        }
        p.orderFrontRegardless()
        panel = p
    }

    @objc private func dismiss() { panel?.orderOut(nil); panel = nil }

    @objc private func openInZCode() {
        let delegate = AppDelegate.shared
        if let ws = workspacePath, !ws.isEmpty {
            delegate?.jumpToZCode(workspacePath: ws)
        } else {
            delegate?.jumpToZCode(workspacePath: nil)
        }
        dismiss()
    }
}

// MARK: - 任务清单 popover（点宠物 → 旁边列出执行中/完成未读，点条目跳转）

final class TaskListPopover {
    static let shared = TaskListPopover()
    private let popover = NSPopover()

    /// 在锚点旁弹出/关闭。行按钮 target/action 交回 AppDelegate，
    /// identifier 约定 "run|<taskId>" / "unread|<taskId>"。
    func toggle(anchor: NSView,
                running: [(title: String, id: String, ws: String)],
                unread: [TaskRow],
                target: AnyObject, action: Selector) {
        if popover.isShown { popover.performClose(nil); return }
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.behavior = .transient   // 点外部自动关
        let vc = NSViewController()
        vc.view = buildView(running: running, unread: unread, target: target, action: action)
        popover.contentViewController = vc
        popover.contentSize = vc.view.frame.size

        // 宠物常贴屏幕右缘：右边放不下就往左弹
        var edge: NSRectEdge = .maxX
        if let win = anchor.window, let vf = win.screen?.visibleFrame {
            if win.frame.maxX + 340 > vf.maxX { edge = .minX }
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
    }

    func close() { popover.performClose(nil) }

    private func buildView(running: [(title: String, id: String, ws: String)],
                           unread: [TaskRow],
                           target: AnyObject, action: Selector) -> NSView {
        let W: CGFloat = 320, rowH: CGFloat = 30, headerH: CGFloat = 22
        let runRows = running.prefix(8)
        let unreadRows = unread.prefix(10)

        var H: CGFloat = 16
        if runRows.isEmpty && unreadRows.isEmpty { H += 34 }
        if !runRows.isEmpty { H += headerH + CGFloat(runRows.count) * rowH + 6 }
        if !unreadRows.isEmpty { H += headerH + CGFloat(unreadRows.count) * rowH + 6 }
        H += 10
        let view = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        var y = H - 14   // AppKit 原点在左下，从顶部往下摆

        func addHeader(_ text: String) {
            let l = NSTextField(labelWithString: text)
            l.font = .boldSystemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 14, y: y - headerH + 3, width: W - 28, height: headerH)
            view.addSubview(l)
            y -= headerH + 2
        }
        func addRow(_ emoji: String, _ title: String, _ key: String) {
            let b = NSButton(title: "\(emoji)  \(title)", target: target, action: action)
            b.isBordered = false
            b.font = .systemFont(ofSize: 12.5)
            b.alignment = .left
            b.lineBreakMode = .byTruncatingTail
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.frame = NSRect(x: 12, y: y - rowH + 2, width: W - 24, height: rowH)
            view.addSubview(b)
            y -= rowH
        }

        if runRows.isEmpty && unreadRows.isEmpty {
            let l = NSTextField(labelWithString: "没有执行中的任务")
            l.font = .systemFont(ofSize: 12.5)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 14, y: y - 30, width: W - 28, height: 22)
            view.addSubview(l)
            return view
        }
        if !runRows.isEmpty {
            addHeader("执行中（\(runRows.count)）")
            for t in runRows { addRow("🔄", t.title, "run|\(t.id)") }
            y -= 8
        }
        if !unreadRows.isEmpty {
            addHeader("完成未读（\(unreadRows.count)）")
            for t in unreadRows {
                addRow(t.status == "error" ? "⚠️" : "✅", shortTitle(t.title), "unread|\(t.id)")
            }
        }
        return view
    }
}

// MARK: - Pet panel（悬浮宠物：点击回 ZCode，拖动移动且位置记忆）

final class PetPanelController {
    private var panel: NSPanel!
    private var emojiField: NSTextField!
    private var artView: NSImageView!          // 手绘皮肤画面
    private var artCache: [String: NSImage] = [:]
    private var captionField: NSTextField!
    private var baseOrigin: NSPoint = .zero
    private var phase: Double = 0
    private var dragging = false
    private var onDragEndHandler: ((NSPoint) -> Void)?
    private(set) var containerView: NSView!   // popover 锚点（v0.6 任务清单）

    static let size = NSSize(width: 104, height: 110)   // v0.5.2 缩小 30%（原 148×158）

    init(savedOrigin: NSPoint?, onClick: @escaping () -> Void, onDragEnd: @escaping (NSPoint) -> Void) {
        onDragEndHandler = onDragEnd
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: PetPanelController.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let container = DragView(frame: NSRect(origin: .zero, size: PetPanelController.size))
        containerView = container
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
        container.layer?.cornerRadius = 18
        container.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.72).cgColor
        container.layer?.masksToBounds = true

        emojiField = NSTextField(labelWithString: "😺")
        emojiField.font = .systemFont(ofSize: 42)
        emojiField.alignment = .center
        emojiField.frame = NSRect(x: 3, y: 44, width: 98, height: 58)

        artView = NSImageView(frame: NSRect(x: 0, y: 40, width: 104, height: 68))
        artView.imageScaling = .scaleNone
        artView.isHidden = true

        captionField = NSTextField(labelWithString: "启动中…")
        captionField.font = .systemFont(ofSize: 11)
        captionField.textColor = NSColor(white: 1.0, alpha: 0.92)
        captionField.alignment = .center
        captionField.lineBreakMode = .byTruncatingTail
        captionField.frame = NSRect(x: 7, y: 20, width: 90, height: 22)

        container.addSubview(artView)
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

        // 拔/接显示器、分辨率变化后把宠物拉回可见区（否则它停在已消失的屏幕坐标上，
        // 窗口还在但永远看不见——v0.5.1 实测：外接屏拔掉后宠物"失踪"）
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.ensureOnScreen(persist: true)
        }
    }

    /// 把窗口夹回 NSScreen.main 可见区，需要时回写持久化位置
    func ensureOnScreen(persist: Bool) {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let x = min(max(panel.frame.origin.x, vf.minX), vf.maxX - PetPanelController.size.width)
        let y = min(max(panel.frame.origin.y, vf.minY), vf.maxY - PetPanelController.size.height)
        guard NSPoint(x: x, y: y) != panel.frame.origin else { return }
        baseOrigin = NSPoint(x: x, y: y)
        panel.setFrameOrigin(baseOrigin)
        if persist { onDragEndHandler?(baseOrigin) }
    }

    func update(mode: PetMode, skin: PetSkin, runningCount: Int, unreadCount: Int) {
        if skin.art != nil {
            // 手绘皮肤：按 skin+mode 渲染一次并缓存
            emojiField.isHidden = true
            artView.isHidden = false
            let key = "\(skin.id)-\(mode)"
            if artCache[key] == nil { artCache[key] = PetArt.image(skin: skin, mode: mode) }
            artView.image = artCache[key]
        } else {
            artView.isHidden = true
            emojiField.isHidden = false
            emojiField.stringValue = skin.emoji(for: mode)
        }
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
    static weak var shared: AppDelegate?

    let config = PetConfig.load()
    var state = PetState.load()
    let store: TaskStore?
    let resultStore: TaskResultStore?
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
    // taskId → 最新行（菜单/通知点击时还原标题、状态、工作区）
    private var rowsById: [String: TaskRow] = [:]
    // UI 缓存
    private var lastRunning: [(title: String, id: String, ws: String)] = []
    private var lastUnread: [TaskRow] = []

    private var mode: PetMode = .idle
    private var modeExpiry: Double = 0
    private var firstPoll = true
    private var lastStateSave = 0.0

    override init() {
        let cfg = PetConfig.load()
        store = TaskStore(path: cfg.dbPath)
        resultStore = TaskResultStore(path: cfg.resultDbPath)
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let saved = state.petOrigin.map { NSPoint(x: CGFloat($0[0]), y: CGFloat($0[1])) }
        pet = PetPanelController(savedOrigin: saved,
                                 onClick: { [weak self] in self?.toggleTaskList() },
                                 onDragEnd: { [weak self] origin in
                                     self?.state.petOrigin = [Double(origin.x), Double(origin.y)]
                                     self?.state.save()
                                 })
        eventTail = EventTail(path: PetConfig.dataDir + "/events.jsonl")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"

        // 安装脚本写的是 🐾 默认图标，启动时换成当前皮肤（marker 命中则秒过）
        AppIconManager.apply(skin: skin)

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
            pet.update(mode: .idle, skin: skin, runningCount: 0, unreadCount: 0)
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

    /// 跳回 ZCode：带工作区时走 --open-workspace（会落在该工作区的新任务上，ZCode 无任务级
        /// 外部入口——故只作为结果面板里用户主动点的按钮）；不带时纯 activate，绝不新建任务。
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
        // activate() 从后台进程调用时对最小化窗口无效（实测返回 true 但窗口不动）；
        // open app URL 等价 Dock 点击（reopen 事件），ZCode 端会恢复并聚焦主窗口
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.zcodeAppBundleId)
            ?? URL(fileURLWithPath: "/Applications/ZCode.app")
        NSWorkspace.shared.open(appURL)
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
        rowsById = byId
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
        pet.update(mode: m, skin: skin, runningCount: running.count, unreadCount: unread.count)
        let base = running.isEmpty ? "🐾" : "🐾 \(running.count)"
        statusItem.button?.title = unread.isEmpty ? base : "\(base) 📬\(unread.count)"
        rebuildMenu(running: running, unread: lastUnread)
    }

    private func rebuildMenu(running: [(title: String, id: String, ws: String)], unread: [TaskRow]) {
        let menu = NSMenu()

        if running.isEmpty {
            menu.addItem(withTitle: "没有执行中的任务", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "执行中（\(running.count)）— 点击看进度", action: nil, keyEquivalent: "")
            for t in running.prefix(8) {
                let item = menu.addItem(withTitle: "  " + t.title,
                                        action: #selector(openTaskResult(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = t.id.isEmpty ? nil : t.id
            }
        }
        menu.addItem(.separator())

        if !unread.isEmpty {
            menu.addItem(withTitle: "完成未读（\(unread.count)）— 点击看结果", action: nil, keyEquivalent: "")
            for t in unread.prefix(10) {
                let prefix = t.status == "error" ? "⚠️ " : "✅ "
                let item = menu.addItem(withTitle: "  " + prefix + shortTitle(t.title),
                                        action: #selector(openTaskResult(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = t.id
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

        menu.addItem(withTitle: "发条测试通知", action: #selector(testNotify), keyEquivalent: "").target = self

        // 宠物造型子菜单
        let skinMenu = NSMenu(title: "宠物造型")
        for s in petSkins {
            let item = NSMenuItem(title: "\(s.glyph)  \(s.name)",
                                  action: #selector(selectSkin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            item.state = (s.id == skin.id) ? .on : .off
            skinMenu.addItem(item)
        }
        let skinItem = menu.addItem(withTitle: "宠物造型 \(skin.glyph)", action: nil, keyEquivalent: "")
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
        AppIconManager.apply(skin: s)
        if let store {
            let rows = store.allTasks()
            let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            updateUI(displayIds: Set(busyIds).union(byId.filter { $0.value.status == "running" }.keys), byId: byId)
        }
    }

    @objc private func openTaskResult(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showResultPanel(taskId: id)
    }

    // MARK: 宠物点击 → 任务清单 popover

    private func toggleTaskList() {
        guard let anchor = pet.containerView else { return }
        TaskListPopover.shared.toggle(anchor: anchor,
                                      running: lastRunning,
                                      unread: lastUnread,
                                      target: self,
                                      action: #selector(taskRowPicked(_:)))
    }

    @objc private func taskRowPicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let sep = key.firstIndex(of: "|") else { return }
        let prefix = String(key[..<sep])
        let id = String(key[key.index(after: sep)...])
        TaskListPopover.shared.close()
        if prefix == "run" {
            if let ws = lastRunning.first(where: { $0.id == id })?.ws, !ws.isEmpty {
                jumpToZCode(workspacePath: ws)
            }
        } else {
            showResultPanel(taskId: id)
        }
    }

    /// 任务结果面板：标题/状态/完成时间来自 tasks-index 快照，正文来自 cli 消息库。
    /// ZCode 没有任务级外部入口（v0.5 调研结论），所以点击就地看结果，不再隐式开工作区。
    func showResultPanel(taskId: String, fallbackTitle: String? = nil, isError: Bool? = nil) {
        let row = rowsById[taskId] ?? store?.allTasks().first { $0.id == taskId }
        let title = shortTitle(row?.title.isEmpty == false ? row!.title : (fallbackTitle ?? "任务"), 40)
        let error = isError ?? (row?.status == "error")
        let running = row?.status == "running"

        var metaParts: [String] = []
        if let ws = row?.workspacePath, !ws.isEmpty {
            metaParts.append((ws as NSString).lastPathComponent)
        }
        if running { metaParts.append("执行中") }
        if let updatedMs = row?.updatedAtMs, updatedMs > 0, !running {
            let date = Date(timeIntervalSince1970: updatedMs / 1000)
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            metaParts.append(error ? "出错于 \(fmt.string(from: date))" : "完成于 \(fmt.string(from: date))")
        }
        let body = resultStore?.lastAssistantText(sessionId: taskId) ?? ""
        TaskResultPanelController.shared.show(
            title: title, isError: error,
            meta: metaParts.joined(separator: " · "),
            body: body, workspacePath: row?.workspacePath)
    }

    /// 验证图标/声音/点击跳转链路是否正常
    @objc private func testNotify() {
        postNotification(taskId: "test", title: "🐾 任务完成", body: "测试通知：检查图标与点击跳转",
                         sound: "Glass", workspacePath: "")
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

// MARK: - UN 通知回调：点击 → 任务结果面板（ZCode 无任务级入口，就地看结果）

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let taskId = info["taskId"] as? String
        if let taskId, taskId != "test" {
            showResultPanel(taskId: taskId,
                            fallbackTitle: info["title"] as? String,
                            isError: (info["title"] as? String)?.contains("出错") ?? false)
        } else {
            // 测试通知：直接弹面板走一遍 UI 链路
            TaskResultPanelController.shared.show(title: "测试通知", isError: false,
                                                  meta: "链路自检", body: "看到这个面板说明点击链路正常。",
                                                  workspacePath: info["workspacePath"] as? String)
        }
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

// MARK: - --notify-test（发一条测试通知后退出：验证横幅图标/声音/点击跳转）

final class NotifyTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = UNMutableNotificationContent()
        content.title = "🐾 任务完成"
        content.body = "测试通知：检查横幅图标与点击跳转"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass"))
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "pet-notify-test", content: content, trigger: nil))
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in NSApp.terminate(nil) }
    }
}

// MARK: - --panel-test <taskId>（用真实库数据拉起任务结果面板，20 秒自动退出）

var panelTestTaskId: String?

final class PanelTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let taskId = panelTestTaskId else { NSApp.terminate(nil); return }
        let cfg = PetConfig.load()
        let store = TaskStore(path: cfg.dbPath)
        let resultStore = TaskResultStore(path: cfg.resultDbPath)
        let row = store?.allTasks().first { $0.id == taskId }
        let body = resultStore?.lastAssistantText(sessionId: taskId) ?? ""
        var meta: [String] = []
        if let ws = row?.workspacePath, !ws.isEmpty { meta.append((ws as NSString).lastPathComponent) }
        meta.append(row?.status ?? "unknown")
        TaskResultPanelController.shared.show(title: shortTitle(row?.title ?? taskId, 40),
                                              isError: row?.status == "error",
                                              meta: meta.joined(separator: " · "),
                                              body: body, workspacePath: row?.workspacePath)
        Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in NSApp.terminate(nil) }
    }
}

// MARK: - main

if CommandLine.arguments.contains("--test") {
    exit(runSelfTest())
}

// --gen-icon <emoji> <out.icns>：给 install.sh 生成默认 🐾 图标（无 GUI，渲染完即退）
if let i = CommandLine.arguments.firstIndex(of: "--gen-icon"), CommandLine.arguments.count > i + 2 {
    let dest = URL(fileURLWithPath: CommandLine.arguments[i + 2])
    let ok = AppIconManager.generate(emoji: CommandLine.arguments[i + 1], to: dest)
    print(ok ? "icon ok: \(dest.path)" : "icon generate failed")
    exit(ok ? 0 : 1)
}

// --render-art <dir>：导出全部手绘皮肤的 4 种状态 + 图标效果 PNG（画得对不对肉眼自检）
if let i = CommandLine.arguments.firstIndex(of: "--render-art"), CommandLine.arguments.count > i + 1 {
    exit(PetArt.exportAll(to: CommandLine.arguments[i + 1]))
}

if CommandLine.arguments.contains("--notify-test") {
    let app = NSApplication.shared
    let delegate = NotifyTestDelegate()   // NSApplication.delegate 是 weak，需强引用
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

// --panel-test <taskId>：用真实库数据拉起任务结果面板（无轮询、20 秒自动退出，链路自检用）
if let i = CommandLine.arguments.firstIndex(of: "--panel-test"), CommandLine.arguments.count > i + 1 {
    panelTestTaskId = CommandLine.arguments[i + 1]
}
if CommandLine.arguments.contains("--panel-test") {
    let app = NSApplication.shared
    let delegate = PanelTestDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
