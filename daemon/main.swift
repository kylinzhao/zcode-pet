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
// v0.7 手绘皮肤：PetSkin 支持可选 art 闭包，画布为 26×17 像素字符矩阵（'.' 透明 + 调色板），
//     面板走 NSImageView、通知图标走同一套渲染；新增樱木花道/白兵，恐龙(trex)由 emoji
//     重绘为像素画。--render-art <dir> 可导出全部手绘皮肤的 PNG 自检（含行宽校验）。
// v0.7.2 图片资产通道：樱木/恐龙/白兵改为 mmx image-01 生成贴纸（daemon/assets/pet/，
//     install.sh 拷入 Resources/pet-art/），面板与图标优先用资产，缺失自动降级像素画。
// v0.8 矢量动画皮肤「球球」（emotion-ball 风格）：PetSkin 新增 animated 标记，art 闭包改由
//     12fps tick 逐帧重绘（PetArt.ballTime 时钟）。渐变圆 + 表情眼 + 眨眼/呼吸，四态情绪体色；
//     形象参数取自 dreamcall520/emotion-ball-desktop-pet 网页演示渲染源码（详见 PetArt 矢量段注释，
//     独立实现、未用其资产；角色原作者 sam70331，免费非商用需署名）。
// v0.9 矢量皮肤家族 + 眼神跟随：PetArt 泛化为 VectorStyle 渲染器（沿其 blob/wedge/gem 三体型思路），
//     新增饭团（海苔）/菱菱（超椭圆菱）/蛋蛋（呆毛+腮红），海苔/呆毛/腮红为原创装饰；
//     14 款 emoji 皮肤下线；眼神跟随鼠标（setEye lookX/lookY 语义）+ 邻近注视
//     （鼠标贴近时瞳孔微放大，蔚来 NOMI 式反应）。
// v1.0 全矢量：面板放大 25%（130×136）字号加大；矢量脸新增嘴部表情与
//     idle 打呵欠（22~34s 一次）；樱木/恐龙/白兵下线（像素画引擎随之移除）。
// v1.1 家族成型：AI 大头贴（mmx）因风格不一致观感廉价被移除；矢量家族新增
//     咪咪(猫耳+摇尾)/兔兔(长耳)/幽幽(波浪裙边+悬浮)，全家族统一设计语言
//     （同渐变/眼型/嘴型/动效）+ 接地软阴影 + 左上高光泽。
// v1.1.1 画布适配：fitGeom 按形状头顶装饰高度自动整身缩放（猫 .77/兔 .75 级别），
//     耳尖/呆毛不再超出 130×84 画布被裁；修接地阴影画到身体上方的问题。
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
    let art: ((PetMode, NSRect) -> Void)?  // 非 nil = 手绘皮肤（像素画作兜底；球球为矢量绘制）
    let asset: Bool                        // true = bundle 里有 pet-art/<id>-<mode>.png 图片资产（mmx 生成）
    let animated: Bool                     // true = 矢量动画皮肤，由 12fps tick 逐帧重绘（眨眼/呼吸）

    init(id: String, name: String, glyph: String? = nil,
         idle: String, working: String, celebrate: String, error: String,
         art: ((PetMode, NSRect) -> Void)? = nil, asset: Bool = false,
         animated: Bool = false) {
        self.id = id
        self.name = name
        self.glyph = glyph ?? idle
        self.idle = idle
        self.working = working
        self.celebrate = celebrate
        self.error = error
        self.art = art
        self.asset = asset
        self.animated = animated
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

// v0.9：纯 emoji 皮肤下线。
// emoji 字段仅作渲染失败时的最后兜底显示。
let petSkins: [PetSkin] = [
    .init(id: "ball", name: "球球", idle: "⚪", working: "🔵", celebrate: "🟡", error: "🔴",
          art: PetArt.vectorPet(.init(shape: .round)), animated: true),
    .init(id: "onigiri", name: "饭团", idle: "🍙", working: "🍙", celebrate: "🎉", error: "😵",
          art: PetArt.vectorPet(.init(shape: .onigiri,
                                      idleColor: NSColor(srgbRed: 0xF2 / 255, green: 0xEE / 255, blue: 0xE3 / 255, alpha: 1),
                                      nori: true)), animated: true),
    .init(id: "gem", name: "菱菱", idle: "💠", working: "💠", celebrate: "🎉", error: "😵",
          art: PetArt.vectorPet(.init(shape: .gem,
                                      idleColor: NSColor(srgbRed: 0x93 / 255, green: 0xDC / 255, blue: 0xCB / 255, alpha: 1),
                                      blush: true)), animated: true),
    .init(id: "egg", name: "蛋蛋", idle: "🥚", working: "🐣", celebrate: "🎉", error: "😵",
          art: PetArt.vectorPet(.init(shape: .egg,
                                      idleColor: NSColor(srgbRed: 0xF6 / 255, green: 0xD6 / 255, blue: 0x8C / 255, alpha: 1),
                                      ahoge: true, blush: true)), animated: true),
    .init(id: "cat", name: "咪咪", idle: "🐱", working: "🐱", celebrate: "🎉", error: "😵",
          art: PetArt.vectorPet(.init(shape: .cat,
                                      idleColor: NSColor(srgbRed: 0xF5 / 255, green: 0xC0 / 255, blue: 0x83 / 255, alpha: 1))), animated: true),
    .init(id: "bunny", name: "兔兔", idle: "🐰", working: "🐰", celebrate: "🎉", error: "😵",
          art: PetArt.vectorPet(.init(shape: .bunny,
                                      idleColor: NSColor(srgbRed: 0xF7 / 255, green: 0xF1 / 255, blue: 0xEE / 255, alpha: 1),
                                      blush: true)), animated: true),
    .init(id: "ghost", name: "幽幽", idle: "👻", working: "👻", celebrate: "🎉", error: "😵",
          art: PetArt.vectorPet(.init(shape: .ghost,
                                      idleColor: NSColor(srgbRed: 0xE9 / 255, green: 0xE5 / 255, blue: 0xF4 / 255, alpha: 1),
                                      blush: true)), animated: true),
]

func currentSkin() -> PetSkin {
    let id = PetState.load().skinId
    return petSkins.first { $0.id == id } ?? petSkins[0]
}

// MARK: - 宠物美术（矢量动画皮肤 + 图片资产皮肤）
//
// 矢量皮肤：PetArt.drawVector 逐帧绘制（眨眼/呼吸/眼神跟随/呵欠），画布 130×84
// 与宠物面板 art 区同比例；--render-art <dir> 可导出全部矢量皮肤的 PNG 自检。

enum PetArt {
    static let W: CGFloat = 130
    static let H: CGFloat = 84

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

    // MARK: 矢量皮肤家族（emotion-ball 风格：渐变身体 + 表情眼，眨眼/呼吸/眼神跟随/呵欠）
    //
    // 形象参考 dreamcall520/emotion-ball-desktop-pet（角色原作者 sam70331，免费非商用需署名）。
    // 基础画法参数取自其网页演示渲染源码，为本项目按参数独立实现的矢量绘制，
    // 未使用其任何美术资产或数据文件：
    //   身体 = 径向渐变焦点 (38%, 32%)、半径 75%，三段 stop（体色 +0.22 / 原色 / -0.12）
    //   眼睛 = #1A1A1A 竖椭圆（圆脸基准：宽 .275R 高 .37R、中心距 .43R、眼心高于球心 .46R）
    //   眨眼 = 间隔 6~14s 随机，合上 → 停 70ms → 过冲 1.08 → 300ms 落回 1
    //   呼吸 = 纵向 ±1%（breathe 0.01）
    //   眼神跟随 = setEye 的 lookX/lookY 语义：眼心向鼠标方向平移（本项目扩展了邻近注视/远处漫游）
    // 全家族统一设计语言：同渐变、同眼型、同嘴型、同动效——角色差异只在于轮廓与装饰
    // （耳/尾/海苔/呆毛/腮红/裙边，均为本项目原创）；接地软阴影 + 左上高光泽提升质感。
    // 情绪体色：idle 各显个性色，working 静心蓝 / celebrate 暖金 / error 珊瑚红家族统一
    // （后三色取自其官网彩带调色板）。

    /// 矢量动画皮肤的动画时钟（秒）与眼神状态，由 PetView.tick 以 12fps 喂
    static var ballTime: CGFloat = 0
    static var gaze = CGPoint.zero     // 平滑后的视向（近似单位向量，右/上为正）
    static var gazeGlow: CGFloat = 0   // 鼠标邻近度 0..1：贴近时瞳孔微放大（注视感）

    enum VectorShape {
        case round      // 球球：正圆
        case onigiri    // 饭团：圆角三角 + 海苔
        case gem        // 菱菱：圆润菱形（超椭圆 n<2）
        case egg        // 蛋蛋：竖椭圆 + 呆毛
        case cat        // 咪咪：圆头 + 猫耳 + 摇尾
        case bunny      // 兔兔：微长圆 + 长耳
        case ghost      // 幽幽：圆顶 + 波浪裙边，悬浮
    }

    struct VectorStyle {
        var shape: VectorShape = .round
        var idleColor: NSColor = NSColor(srgbRed: 0xF3 / 255, green: 0xF0 / 255, blue: 0xEA / 255, alpha: 1)
        var nori = false    // 饭团海苔
        var ahoge = false   // 蛋蛋呆毛
        var blush = false   // 腮红
    }

    private static let ballInk = NSColor(srgbRed: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255, alpha: 1)
    private static let innerPink = NSColor(srgbRed: 0xF2 / 255, green: 0xB8 / 255, blue: 0xC6 / 255, alpha: 0.9)
    private static let moodWorking = NSColor(srgbRed: 0x7F / 255, green: 0xA8 / 255, blue: 0xEE / 255, alpha: 1)
    private static let moodCelebrate = NSColor(srgbRed: 0xF5 / 255, green: 0xB1 / 255, blue: 0x3F / 255, alpha: 1)
    private static let moodError = NSColor(srgbRed: 0xF9 / 255, green: 0x70 / 255, blue: 0x5C / 255, alpha: 1)

    private static func bodyColor(_ style: VectorStyle, _ mode: PetMode) -> NSColor {
        switch mode {
        case .idle: return style.idleColor
        case .working: return moodWorking
        case .celebrate: return moodCelebrate
        case .error: return moodError
        }
    }

    /// 官网 shade()：sRGB 分量向黑/白线性插值（amt>0 变亮、<0 变暗）
    private static func shade(_ c: NSColor, _ amt: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let target: CGFloat = amt < 0 ? 0 : 1
        let a = abs(amt)
        func mix(_ v: CGFloat) -> CGFloat { v + (target - v) * a }
        return NSColor(srgbRed: mix(s.redComponent), green: mix(s.greenComponent),
                       blue: mix(s.blueComponent), alpha: 1)
    }

    /// 确定性伪随机 0..1（SplitMix64）：眨眼/呵欠时刻序列固定，静态导出与运行时一致
    private static func ballHash(_ k: Int) -> CGFloat {
        var x = UInt64(truncatingIfNeeded: k) &+ 0x9E3779B97F4A7C15
        x ^= x >> 30; x &*= 0xBF58476D1CE4E5B9
        x ^= x >> 27; x &*= 0x94D049BB133111EB
        x ^= x >> 31
        return CGFloat(Double(x >> 11) / Double(1 << 53))
    }

    /// t 秒的眼睛开合度：先定位 t 之前最近一次眨眼起点，再按关键帧取值
    private static func blinkOpenness(_ t: CGFloat) -> CGFloat {
        var start: CGFloat = 3.2
        var k = 0
        while k < 10000 {
            let gap: CGFloat = 6 + ballHash(k &+ 77) * 8
            if start + gap > t { break }
            start += gap
            k += 1
        }
        let u = t - start
        if u < 0 { return 1 }
        if u < 0.06 { return 1 - u / 0.06 }                      // 合上
        if u < 0.13 { return 0 }                                 // 停 70ms
        if u < 0.25 { let p = (u - 0.13) / 0.12                  // 睁到 1.08（smoothstep）
            return 1.08 * (p * p * (3 - 2 * p)) }
        if u < 0.55 { return 1.08 - 0.08 * (u - 0.25) / 0.3 }    // 300ms 落回 1
        return 1
    }

    /// t 秒的呵欠幅度 0..1：每 22~34s 一次（仅 idle 用），2.6s 序列 = 张开 0.7s → 保持 1s → 闭合 0.9s
    static func yawnAmount(_ t: CGFloat) -> CGFloat {
        var start: CGFloat = 9.0
        var k = 0
        while k < 10000 {
            let gap: CGFloat = 22 + ballHash(k &+ 913) * 12
            if start + gap > t { break }
            start += gap
            k += 1
        }
        let u = t - start
        if u < 0 || u > 2.6 { return 0 }
        if u < 0.7 { let p = u / 0.7; return p * p * (3 - 2 * p) }
        if u < 1.7 { return 1 }
        let p = (u - 1.7) / 0.9
        return 1 - p * p * (3 - 2 * p)
    }

    /// 超椭圆 |x/a|^n + |y/b|^n = 1 采样折线（n=2 椭圆，n<2 趋向菱形）
    private static func superellipse(a: CGFloat, b: CGFloat, n: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let pts = 48
        for i in 0...pts {
            let th = CGFloat(i) / CGFloat(pts) * 2 * .pi
            let e = 2 / n
            let x = a * pow(abs(cos(th)), e) * (cos(th) < 0 ? -1 : 1)
            let y = b * pow(abs(sin(th)), e) * (sin(th) < 0 ? -1 : 1)
            i == 0 ? p.move(to: NSPoint(x: x, y: y)) : p.line(to: NSPoint(x: x, y: y))
        }
        p.close()
        return p
    }

    /// 身体轮廓（局部坐标，中心 (0,0)，R = 名义半径）
    private static func bodyPath(_ shape: VectorShape, R: CGFloat) -> NSBezierPath {
        switch shape {
        case .round, .cat:
            return NSBezierPath(ovalIn: NSRect(x: -R, y: -R, width: 2 * R, height: 2 * R))
        case .egg:
            return NSBezierPath(ovalIn: NSRect(x: -0.80 * R, y: -R, width: 1.60 * R, height: 2 * R))
        case .bunny:
            return NSBezierPath(ovalIn: NSRect(x: -0.85 * R, y: -R, width: 1.70 * R, height: 2 * R))
        case .gem:
            return superellipse(a: R, b: 0.94 * R, n: 1.4)
        case .ghost:
            // 圆顶 + 三段波浪裙边（裙边朝下）
            let p = NSBezierPath()
            let w: CGFloat = 1.70 * R / 3
            p.move(to: NSPoint(x: -0.85 * R, y: -0.30 * R))
            p.curve(to: NSPoint(x: 0, y: R),
                    controlPoint1: NSPoint(x: -0.92 * R, y: 0.52 * R),
                    controlPoint2: NSPoint(x: -0.56 * R, y: R))
            p.curve(to: NSPoint(x: 0.85 * R, y: -0.30 * R),
                    controlPoint1: NSPoint(x: 0.56 * R, y: R),
                    controlPoint2: NSPoint(x: 0.92 * R, y: 0.52 * R))
            var x = 0.85 * R
            for _ in 0..<3 {
                p.curve(to: NSPoint(x: x - w, y: -0.30 * R),
                        controlPoint1: NSPoint(x: x - w * 0.25, y: -0.78 * R),
                        controlPoint2: NSPoint(x: x - w * 0.75, y: -0.78 * R))
                x -= w
            }
            p.close()
            return p
        case .onigiri:
            // 圆顶三角（饭团）：圆顶弧 + 微内凹侧边 + 圆角平底
            let p = NSBezierPath()
            let top = 0.92 * R, base = -0.78 * R, halfW = 0.85 * R
            p.move(to: NSPoint(x: -0.10 * R, y: top))
            p.curve(to: NSPoint(x: 0.10 * R, y: top),                     // 圆顶
                    controlPoint1: NSPoint(x: -0.035 * R, y: top + 0.065 * R),
                    controlPoint2: NSPoint(x: 0.035 * R, y: top + 0.065 * R))
            p.curve(to: NSPoint(x: halfW, y: base),                       // 右边微内凹
                    controlPoint1: NSPoint(x: 0.60 * R, y: 0.55 * R),
                    controlPoint2: NSPoint(x: 0.83 * R, y: -0.28 * R))
            p.curve(to: NSPoint(x: -halfW, y: base),                      // 平底 + 圆底角
                    controlPoint1: NSPoint(x: 0.45 * R, y: base),
                    controlPoint2: NSPoint(x: -0.45 * R, y: base))
            p.curve(to: NSPoint(x: -0.10 * R, y: top),                    // 左边微内凹
                    controlPoint1: NSPoint(x: -0.83 * R, y: -0.28 * R),
                    controlPoint2: NSPoint(x: -0.60 * R, y: 0.55 * R))
            p.close()
            return p
        }
    }

    /// 形状相关的脸部参数：眼缩放 / 眼心高度 / 两眼中心距（越窄的脸眼睛越靠中、越小）
    private static func faceGeom(_ shape: VectorShape, R: CGFloat) -> (scale: CGFloat, eyeY: CGFloat, gap: CGFloat) {
        switch shape {
        case .round, .cat: return (0.95, 0.42 * R, 0.40 * R)
        case .egg:   return (0.92, 0.40 * R, 0.40 * R)
        case .bunny: return (0.88, 0.38 * R, 0.36 * R)
        case .onigiri: return (0.85, 0.06 * R, 0.38 * R)
        case .ghost: return (0.85, 0.12 * R, 0.38 * R)
        case .gem:   return (0.78, 0.16 * R, 0.34 * R)
        }
    }

    /// 身体上/下沿（R 的倍数）：决定整身缩放——头顶装饰（耳/呆毛）与底部都要留在画布内
    private static func fitGeom(_ shape: VectorShape) -> (top: CGFloat, bottom: CGFloat) {
        switch shape {
        case .round, .cat: return (1.30, 1.0)     // 猫取耳尖
        case .egg:   return (1.22, 1.0)           // 呆毛
        case .bunny: return (1.34, 1.0)           // 耳尖
        case .onigiri, .ghost: return (0.99, 0.78)
        case .gem:   return (0.94, 0.94)
        }
    }

    /// 猫耳轮廓（局部坐标，side = ±1，y 向上；画在身体后面，根部被头挡住）
    private static func catEar(_ side: CGFloat, _ R: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: side * 0.26 * R, y: 0.68 * R))
        p.curve(to: NSPoint(x: side * 0.58 * R, y: 1.30 * R),
                controlPoint1: NSPoint(x: side * 0.30 * R, y: 1.06 * R),
                controlPoint2: NSPoint(x: side * 0.42 * R, y: 1.28 * R))
        p.curve(to: NSPoint(x: side * 0.78 * R, y: 0.40 * R),
                controlPoint1: NSPoint(x: side * 0.74 * R, y: 1.10 * R),
                controlPoint2: NSPoint(x: side * 0.84 * R, y: 0.72 * R))
        p.close()
        return p
    }

    /// 兔耳（局部坐标，side = ±1，y 向上）：微外撇的长椭圆
    private static func drawBunnyEar(_ side: CGFloat, _ R: CGFloat, color: NSColor, inner: Bool) {
        NSGraphicsContext.current?.saveGraphicsState()
        let tr = NSAffineTransform()
        tr.translateX(by: side * 0.30 * R, yBy: 0.86 * R)
        tr.rotate(byDegrees: side * 10)
        tr.concat()
        if inner {
            innerPink.setFill()
            NSBezierPath(ovalIn: NSRect(x: -0.11 * R, y: -0.34 * R, width: 0.22 * R, height: 0.68 * R)).fill()
        } else {
            shade(color, 0.04).setFill()
            shade(color, -0.3).withAlphaComponent(0.5).setStroke()
            let ear = NSBezierPath(ovalIn: NSRect(x: -0.21 * R, y: -0.48 * R, width: 0.42 * R, height: 0.96 * R))
            ear.lineWidth = 0.8
            ear.fill()
            ear.stroke()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// art 闭包工厂：petSkins 条目用
    static func vectorPet(_ style: VectorStyle) -> ((PetMode, NSRect) -> Void) {
        { mode, rect in drawVector(style, mode, in: rect) }
    }

    static func drawVector(_ style: VectorStyle, _ mode: PetMode, in rect: NSRect) {
        let R0 = min(rect.width, rect.height) / 2 - 2
        let cy = rect.midY
        let color = bodyColor(style, mode)
        let breathe = 1 + 0.01 * sin(2 * .pi * 0.15 * ballTime)   // 呼吸 ±1%，锚在中心
        let isGhost = style.shape == .ghost
        // 幽灵悬浮：慢速上下漂
        let hover: CGFloat = isGhost ? 0.5 + 0.5 * sin(2 * .pi * 0.45 * ballTime) : 0

        // 整身缩放：头顶装饰与底部都留在画布内（fit 由形状的上/下沿决定）
        let fit = fitGeom(style.shape)
        let s = min(0.96, (cy - 2) / (fit.top * R0), (cy - 3) / (fit.bottom * R0))
        let R = R0 * s

        // 接地软阴影（先画，在身体后面；幽灵悬浮越高影越淡）
        let shadowCenterY = cy - fit.bottom * R + 1.5
        let shadow = NSBezierPath(ovalIn: NSRect(x: rect.midX - 0.55 * R, y: shadowCenterY - 0.065 * R,
                                                 width: 1.10 * R, height: 0.13 * R))
        NSColor.black.withAlphaComponent(0.13 * (1 - 0.55 * hover)).setFill()
        shadow.fill()

        // 呼吸/悬浮/整身缩放变换包住整个身体与五官
        NSGraphicsContext.current?.saveGraphicsState()
        let tr = NSAffineTransform()
        tr.translateX(by: rect.midX, yBy: cy - hover * 0.04 * R)
        tr.scaleX(by: s, yBy: s * breathe)
        tr.concat()

        // 身后装饰：猫耳 + 猫尾（渐变身体画在上面盖住根部）
        if case .cat = style.shape {
            let tailWag = sin(2 * .pi * (mode == .working ? 0.8 : 0.22) * ballTime) * (mode == .idle ? 10 : 4)
            NSGraphicsContext.current?.saveGraphicsState()
            let tw = NSAffineTransform()
            tw.translateX(by: 0.74 * R, yBy: -0.10 * R)
            tw.rotate(byDegrees: tailWag)
            tw.translateX(by: -0.74 * R, yBy: 0.10 * R)
            tw.concat()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 0.74 * R, y: -0.10 * R))
            tail.curve(to: NSPoint(x: 1.24 * R, y: 0.30 * R),
                       controlPoint1: NSPoint(x: 1.06 * R, y: -0.02 * R),
                       controlPoint2: NSPoint(x: 1.26 * R, y: 0.12 * R))
            tail.curve(to: NSPoint(x: 0.96 * R, y: 0.88 * R),
                       controlPoint1: NSPoint(x: 1.24 * R, y: 0.52 * R),
                       controlPoint2: NSPoint(x: 1.14 * R, y: 0.74 * R))
            shade(color, -0.06).setStroke()
            tail.lineWidth = 0.17 * R
            tail.lineCapStyle = .round
            tail.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
            for side in [-1.0, 1.0] {
                let ear = catEar(side, R)
                shade(color, 0.04).setFill()
                ear.fill()
                shade(color, -0.3).withAlphaComponent(0.5).setStroke()
                ear.lineWidth = 0.8
                ear.stroke()
            }
        }
        if case .bunny = style.shape {
            for side in [-1.0, 1.0] { drawBunnyEar(side, R, color: color, inner: false) }
        }

        let body = bodyPath(style.shape, R: R)

        // 三段径向渐变 + 左上高光泽，焦点在左上（官网 cx 38% / cy 32%，AppKit y 向上 → 68%）
        NSGraphicsContext.current?.saveGraphicsState()
        body.addClip()
        let focus = NSPoint(x: -0.24 * R, y: 0.36 * R)
        if let grad = NSGradient(colors: [shade(color, 0.22), color, shade(color, -0.12)],
                                 atLocations: [0, 0.62, 1], colorSpace: .sRGB) {
            grad.draw(fromCenter: focus, radius: 0, toCenter: focus, radius: 1.5 * R, options: [])
        }
        if let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.42),
                                           NSColor.white.withAlphaComponent(0)]) {
            gloss.draw(fromCenter: NSPoint(x: -0.30 * R, y: 0.46 * R), radius: 0,
                       toCenter: NSPoint(x: -0.30 * R, y: 0.46 * R), radius: 0.52 * R, options: [])
        }
        // 饭团海苔：身体 clip 内的底部圆角深绿块
        if style.nori {
            NSColor(srgbRed: 0x33 / 255, green: 0x50 / 255, blue: 0x3F / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: -0.54 * R, y: -0.80 * R, width: 1.08 * R, height: 0.46 * R),
                         xRadius: 0.10 * R, yRadius: 0.10 * R).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        shade(color, -0.3).withAlphaComponent(0.5).setStroke()    // 淡轮廓：浅色桌面下兜住边缘
        body.lineWidth = 0.8
        body.stroke()

        // 蛋蛋呆毛：顶点伸出的一根卷曲小弧
        if style.ahoge {
            let ah = NSBezierPath()
            ah.move(to: NSPoint(x: 0, y: 0.98 * R))
            ah.curve(to: NSPoint(x: 0.24 * R, y: 1.12 * R),
                     controlPoint1: NSPoint(x: 0.05 * R, y: 1.22 * R),
                     controlPoint2: NSPoint(x: 0.22 * R, y: 1.22 * R))
            ah.lineWidth = 0.045 * R
            ah.lineCapStyle = .round
            shade(color, -0.25).setStroke()
            ah.stroke()
        }
        // 猫耳内耳 / 兔耳内耳（画在身体之上，落在耳尖区域）
        if case .cat = style.shape {
            for side in [-1.0, 1.0] {
                // 内耳 = 耳朵轮廓向质心收缩的小一号耳形
                let c = NSPoint(x: side * 0.52 * R, y: 0.78 * R)
                let inner = NSBezierPath()
                inner.move(to: NSPoint(x: c.x + (side * 0.26 * R - c.x) * 0.55, y: c.y + (0.68 * R - c.y) * 0.55))
                inner.curve(to: NSPoint(x: c.x + (side * 0.58 * R - c.x) * 0.55, y: c.y + (1.22 * R - c.y) * 0.55),
                            controlPoint1: NSPoint(x: c.x + (side * 0.30 * R - c.x) * 0.55, y: c.y + (1.00 * R - c.y) * 0.55),
                            controlPoint2: NSPoint(x: c.x + (side * 0.42 * R - c.x) * 0.55, y: c.y + (1.20 * R - c.y) * 0.55))
                inner.curve(to: NSPoint(x: c.x + (side * 0.76 * R - c.x) * 0.55, y: c.y + (0.48 * R - c.y) * 0.55),
                            controlPoint1: NSPoint(x: c.x + (side * 0.72 * R - c.x) * 0.55, y: c.y + (1.04 * R - c.y) * 0.55),
                            controlPoint2: NSPoint(x: c.x + (side * 0.82 * R - c.x) * 0.55, y: c.y + (0.70 * R - c.y) * 0.55))
                inner.close()
                innerPink.setFill()
                inner.fill()
            }
        }
        if case .bunny = style.shape {
            for side in [-1.0, 1.0] { drawBunnyEar(side, R, color: color, inner: true) }
        }

        let g = faceGeom(style.shape, R: R)

        // 腮红：error 模式收起（有怒眉），其余状态两眼外侧淡粉
        var showBlush = style.blush
        if case .error = mode { showBlush = false }
        if showBlush {
            NSColor(srgbRed: 0xEE / 255, green: 0x9B / 255, blue: 0x9B / 255, alpha: 0.38).setFill()
            for side in [-1.0, 1.0] {
                NSBezierPath(ovalIn: NSRect(x: side * (g.gap / 2 + 0.275 * R * g.scale) - 0.075 * R,
                                            y: g.eyeY - 0.14 * R - 0.045 * R,
                                            width: 0.15 * R, height: 0.09 * R)).fill()
            }
        }

        // 眼睛：宽高比例来自官网默认表情眼环；gaze 平移眼心；邻近注视时瞳孔微放大
        let eyeW = 0.275 * R * g.scale * (1 + 0.12 * gazeGlow)
        let eyeH = 0.37 * R * g.scale
        let gx = gaze.x * eyeW * 0.34
        let gy = gaze.y * eyeH * 0.20

        switch mode {
        case .celebrate:
            // 笑眼：下弯弧 + 圆头粗线
            for side in [-1.0, 1.0] {
                let ex = side * g.gap / 2 + gx
                let ey = g.eyeY + gy
                let p = NSBezierPath()
                p.move(to: NSPoint(x: ex - eyeW / 2, y: ey + eyeH * 0.2))
                p.curve(to: NSPoint(x: ex + eyeW / 2, y: ey + eyeH * 0.2),
                        controlPoint1: NSPoint(x: ex - eyeW * 0.18, y: ey - eyeH * 0.42),
                        controlPoint2: NSPoint(x: ex + eyeW * 0.18, y: ey - eyeH * 0.42))
                p.lineWidth = eyeH * 0.34
                p.lineCapStyle = .round
                ballInk.setStroke()
                p.stroke()
            }
        case .error:
            // 怒眼：八字眉 + 压扁的眼
            for side in [-1.0, 1.0] {
                let ex = side * g.gap / 2 + gx
                let ey = g.eyeY + gy
                let brow = NSBezierPath()
                brow.move(to: NSPoint(x: ex + side * eyeW * 0.62, y: ey + eyeH * 0.62))
                brow.line(to: NSPoint(x: ex - side * eyeW * 0.42, y: ey + eyeH * 0.18))
                brow.lineWidth = max(1.1, eyeH * 0.14)
                brow.lineCapStyle = .round
                ballInk.setStroke()
                brow.stroke()
                let h = eyeH * 0.45
                ballInk.setFill()
                NSBezierPath(ovalIn: NSRect(x: ex - eyeW / 2, y: ey - h / 2,
                                            width: eyeW, height: h)).fill()
            }
        default:
            // 睁眼（idle / working）：竖椭圆 × 眨眼开合度；working 专注微眯；idle 呵欠时挤眯
            var open = blinkOpenness(ballTime)
            var ey = g.eyeY
            let yawn: CGFloat = mode == .idle ? yawnAmount(ballTime) : 0
            open *= 1 - 0.75 * yawn
            if case .working = mode { open *= 0.85; ey += eyeH * 0.12 }
            let h = max(eyeH * open, 1.1)                          // 闭合时留一条线
            ballInk.setFill()
            for side in [-1.0, 1.0] {
                let ex = side * g.gap / 2 + gx
                NSBezierPath(ovalIn: NSRect(x: ex - eyeW / 2, y: ey + gy - h / 2,
                                            width: eyeW, height: h)).fill()
            }
        }

        // 嘴巴：表情点睛（呵欠张嘴 > 一切）。位置 = 眼下 0.28R，避开饭团海苔
        let mouthY = g.eyeY + gy - 0.28 * R
        let mouthW = 0.14 * R * g.scale
        let mouth = NSBezierPath()
        mouth.lineCapStyle = .round
        switch mode {
        case .celebrate:
            // 大笑：张开的椭圆嘴
            ballInk.setFill()
            NSBezierPath(ovalIn: NSRect(x: -mouthW * 1.15, y: mouthY - 0.09 * R,
                                        width: mouthW * 2.3, height: 0.17 * R)).fill()
        case .error:
            // 撇嘴：上弯弧
            mouth.move(to: NSPoint(x: -mouthW, y: mouthY - 0.035 * R))
            mouth.curve(to: NSPoint(x: mouthW, y: mouthY - 0.035 * R),
                        controlPoint1: NSPoint(x: -mouthW * 0.4, y: mouthY + 0.045 * R),
                        controlPoint2: NSPoint(x: mouthW * 0.4, y: mouthY + 0.045 * R))
            mouth.lineWidth = 0.045 * R
            ballInk.setStroke()
            mouth.stroke()
        case .working:
            // 认真抿嘴：短平线
            mouth.move(to: NSPoint(x: -mouthW * 0.7, y: mouthY))
            mouth.line(to: NSPoint(x: mouthW * 0.7, y: mouthY))
            mouth.lineWidth = 0.04 * R
            ballInk.setStroke()
            mouth.stroke()
        case .idle:
            let yawn = yawnAmount(ballTime)
            if yawn > 0.02 {
                // 打呵欠：张圆嘴，越困越大
                ballInk.setFill()
                NSBezierPath(ovalIn: NSRect(x: -mouthW * (0.6 + 0.4 * yawn),
                                            y: mouthY - 0.11 * R * yawn,
                                            width: mouthW * 2 * (0.6 + 0.4 * yawn),
                                            height: 0.22 * R * yawn)).fill()
            } else {
                // 微笑：下弯浅弧
                mouth.move(to: NSPoint(x: -mouthW * 0.8, y: mouthY + 0.03 * R))
                mouth.curve(to: NSPoint(x: mouthW * 0.8, y: mouthY + 0.03 * R),
                            controlPoint1: NSPoint(x: -mouthW * 0.3, y: mouthY - 0.035 * R),
                            controlPoint2: NSPoint(x: mouthW * 0.3, y: mouthY - 0.035 * R))
                mouth.lineWidth = 0.045 * R
                ballInk.setStroke()
                mouth.stroke()
            }
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // MARK: 图片资产皮肤（mmx 生成，bundle Resources/pet-art/，缺失时自动降级像素画/emoji）

    private static var assetCache: [String: NSImage?] = [:]

    static func assetImage(id: String, mode: PetMode) -> NSImage? {
        let key = "\(id)-\(modeName(mode))"
        if let cached = assetCache[key] { return cached }
        let img = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("pet-art/\(key).png") }
            .flatMap { NSImage(contentsOf: $0) }
        assetCache[key] = .some(img)
        return img
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

    /// 皮肤 → icns：图片资产 > 像素画 > emoji
    static func generate(skin: PetSkin, to dest: URL) -> Bool {
        generateTo(dest) { size in
            if skin.asset, let img = PetArt.assetImage(id: skin.id, mode: .idle) {
                drawAsset(img, size: size)
            } else if skin.art != nil {
                drawArt(skin, size: size)
            } else {
                drawEmoji(skin.idle, size: size)
            }
        }
    }

    /// 图标 PNG 预览（--render-art 自检用）
    static func renderIconPNG(skin: PetSkin, pixels: Int, to url: URL) -> Bool {
        writePNG(content: { size in
            if skin.asset, let img = PetArt.assetImage(id: skin.id, mode: .idle) {
                drawAsset(img, size: size)
            } else if skin.art != nil {
                drawArt(skin, size: size)
            } else {
                drawEmoji(skin.idle, size: size)
            }
        }, pixels: pixels, to: url)
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

    /// 图片资产等比放进图标内框（assets 是透明底方图，直接适配）
    private static func drawAsset(_ img: NSImage, size: CGFloat) {
        let rect = NSRect(x: size * 0.04, y: size * 0.04, width: size * 0.92, height: size * 0.92)
        let scale = min(rect.width / img.size.width, rect.height / img.size.height)
        let w = img.size.width * scale, h = img.size.height * scale
        img.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
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
    private var activeSkin: PetSkin?           // tick 逐帧重绘动画皮肤（球球）用
    private var captionField: NSTextField!
    private var baseOrigin: NSPoint = .zero
    private var phase: Double = 0
    private var dragging = false
    private var onDragEndHandler: ((NSPoint) -> Void)?
    private(set) var containerView: NSView!   // popover 锚点（v0.6 任务清单）

    static let size = NSSize(width: 130, height: 136)   // v0.9 放大 25%（原 104×110），字更清楚

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
        container.layer?.cornerRadius = 20
        container.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.72).cgColor
        container.layer?.masksToBounds = true

        emojiField = NSTextField(labelWithString: "😺")
        emojiField.font = .systemFont(ofSize: 50)
        emojiField.alignment = .center
        emojiField.frame = NSRect(x: 3, y: 50, width: 124, height: 72)

        artView = NSImageView(frame: NSRect(x: 0, y: 46, width: 130, height: 84))
        artView.imageScaling = .scaleProportionallyUpOrDown   // 资产图 512²，等比缩到面板框
        artView.isHidden = true

        captionField = NSTextField(labelWithString: "启动中…")
        captionField.font = .systemFont(ofSize: 12.5)
        captionField.textColor = NSColor(white: 1.0, alpha: 0.92)
        captionField.alignment = .center
        captionField.lineBreakMode = .byTruncatingTail
        captionField.frame = NSRect(x: 7, y: 10, width: 116, height: 26)

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
        activeSkin = skin
        if skin.asset, let img = PetArt.assetImage(id: skin.id, mode: mode) {
            // 图片资产皮肤（mmx 生成）
            emojiField.isHidden = true
            artView.isHidden = false
            artView.image = img
        } else if skin.art != nil {
            // 手绘皮肤：像素画按 skin+mode 渲染一次并缓存；矢量动画皮肤由 tick 逐帧重绘
            emojiField.isHidden = true
            artView.isHidden = false
            if skin.animated {
                artView.image = PetArt.image(skin: skin, mode: mode)
            } else {
                let key = "\(skin.id)-\(mode)"
                if artCache[key] == nil { artCache[key] = PetArt.image(skin: skin, mode: mode) }
                artView.image = artCache[key]
            }
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
        PetArt.ballTime += 1.0 / 12.0
        var dy: CGFloat = 0
        switch mode {
        case .working: dy = CGFloat(sin(phase * 2 * .pi * 0.8)) * 4
        case .celebrate: dy = abs(CGFloat(sin(phase * 2 * .pi * 1.6))) * -12
        case .error: dy = CGFloat(sin(phase * 2 * .pi * 6.0)) * 2
        case .idle: dy = CGFloat(sin(phase * 2 * .pi * 0.15)) * 2
        }
        panel.setFrameOrigin(NSPoint(x: baseOrigin.x, y: baseOrigin.y + dy))
        // 矢量动画皮肤（球球一族）：眼神跟随 + 眨眼/呼吸逐帧重画。208×136 位图 12fps，开销可忽略
        if let skin = activeSkin, skin.animated, !artView.isHidden {
            updateGaze()
            artView.image = PetArt.image(skin: skin, mode: mode)
        }
    }

    /// 眼神跟随：读全局鼠标位置，视向单位向量逐帧平滑逼近（自然扫视速度）；
    /// 鼠标贴近（~90pt 内）时 gazeGlow → 1，瞳孔微放大——蔚来 NOMI 式"靠近就注视你"。
    /// 鼠标远离（>380pt 渐进）后交给慢速漫游（双正弦叠加的游移视线），不死盯光标。
    private func updateGaze() {
        guard let panel else { return }
        let m = NSEvent.mouseLocation
        let eye = NSPoint(x: panel.frame.midX, y: panel.frame.midY + 30)
        let dx = m.x - eye.x, dy = m.y - eye.y
        let d = max((dx * dx + dy * dy).squareRoot(), 1)
        let t = PetArt.ballTime
        let wx = sin(t * 0.35) * 0.7 + sin(t * 0.13 + 1.7) * 0.3
        let wy = sin(t * 0.21 + 0.8) * 0.35
        let w = max(0, min(1, CGFloat((d - 380) / 320)))       // 380→700pt 混入漫游
        let tx = CGFloat(dx / d) * (1 - w) + wx * w
        let ty = CGFloat(dy / d) * (1 - w) + wy * w
        let len = max((tx * tx + ty * ty).squareRoot(), 1)
        PetArt.gaze.x += (tx / len - PetArt.gaze.x) * 0.35
        PetArt.gaze.y += (ty / len - PetArt.gaze.y) * 0.35
        let near = max(0, 1 - (d - 90) / 260)
        PetArt.gazeGlow += (near - PetArt.gazeGlow) * 0.25
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

// MARK: - ZCode 唤起（AX 直操窗口，绕过后台激活限制）

enum ZCodeActivator {
    /// 纯 AX 把 ZCode 拉到前台：设 frontmost + 取消窗口最小化 + AXRaise。
    /// NSWorkspace.open / activate() 从后台守护进程调用会被 macOS 静默忽略
    /// （实测最小化窗口唤不起）；AX 不受此限制，但需要辅助功能授权（首次弹一次）。
    @discardableResult
    static func raise(bundleId: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleId && $0.activationPolicy == .regular }) else { return false }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var wins: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &wins) == .success,
           let ws = wins as? [AXUIElement] {
            for w in ws {
                AXUIElementSetAttributeValue(w, "AXMinimized" as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(w, "AXMain" as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(w, "AXRaise" as CFString)
            }
        }
        return true
    }

    /// AX 可用性（prompt=true 时弹系统授权引导，用户允许一次后永久生效）
    static func trusted(prompt: Bool = false) -> Bool {
        let opts = prompt ? [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary : nil
        return AXIsProcessTrustedWithOptions(opts)
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

    /// 跳回 ZCode：带工作区时 spawn --open-workspace（单实例转发），再 AX 直操把窗口
    /// 拉到眼前（后台进程的 NSWorkspace.open/activate 会被 macOS 静默忽略——实测
    /// "Dock 图标一闪而过"即转发进程退出后什么都不发生）。AX 无授权时退回 open。
    /// 不用 zcode://workspace/open 深链——主进程对深链无条件弹确认框（3.14.0 实测源码）。
    func jumpToZCode(workspacePath: String?) {
        if let ws = workspacePath, !ws.isEmpty, let exe = zcodeExecutablePath() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            proc.arguments = ["--open-workspace", ws]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            if (try? proc.run()) != nil {
                raiseZCode()
                return
            }
        }
        raiseZCode()
    }

    /// AX 唤起；未授权时弹一次引导并退回 NSWorkspace.open（等价 Dock 点击 reopen）
    private func raiseZCode() {
        if ZCodeActivator.trusted() {
            ZCodeActivator.raise(bundleId: config.zcodeAppBundleId)
        } else {
            ZCodeActivator.trusted(prompt: true)   // 引导用户在系统设置里授权（一次性）
            openZCodeApp()
        }
    }

    private func openZCodeApp() {
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
            menu.addItem(withTitle: "执行中（\(running.count)）— 点击跳转", action: nil, keyEquivalent: "")
            for t in running.prefix(8) {
                let item = menu.addItem(withTitle: "  " + t.title,
                                        action: #selector(openTaskResult(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = t.id.isEmpty ? nil : t.id
            }
        }
        menu.addItem(.separator())

        if !unread.isEmpty {
            menu.addItem(withTitle: "完成未读（\(unread.count)）— 点击跳转", action: nil, keyEquivalent: "")
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

        // 宠物造型子菜单：art 皮肤（矢量）用渲染缩略图当图标（垫透明边距留出图文间距）
        let skinMenu = NSMenu(title: "宠物造型")
        for s in petSkins {
            let hasArt = s.art != nil
            let item = NSMenuItem(title: hasArt ? s.name : "\(s.glyph)  \(s.name)",
                                  action: #selector(selectSkin(_:)), keyEquivalent: "")
            item.target = self
            if hasArt {
                let pad = NSImage(size: NSSize(width: 36, height: 22))
                pad.lockFocus()
                let thumb = PetArt.image(skin: s, mode: .idle)
                thumb.draw(in: NSRect(x: 5, y: 2.5, width: 26, height: 17),
                           from: .zero, operation: .sourceOver, fraction: 1)
                pad.unlockFocus()
                pad.isTemplate = false
                item.image = pad
            }
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
        // 菜单与清单同语义：直达 ZCode 对应工作区（弹窗只留给通知点击）
        guard let id = sender.representedObject as? String else { return }
        jumpToZCode(workspacePath: rowsById[id]?.workspacePath)
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
        // 清单点击=直达 ZCode（用户 v0.6.1）：执行中跳该工作区；未读也跳（弹窗只留给通知点击）
        let ws = prefix == "run"
            ? lastRunning.first(where: { $0.id == id })?.ws
            : lastUnread.first(where: { $0.id == id })?.workspacePath
        jumpToZCode(workspacePath: ws)
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

// MARK: - --jump-test（唤起链路自检：AX 前置 ZCode，验证授权与最小化恢复）

final class JumpTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let trusted = ZCodeActivator.trusted(prompt: true)
        print("ax trusted   : \(trusted)")
        if trusted {
            let ok = ZCodeActivator.raise(bundleId: "dev.zcode.app")
            print("ax raise     : \(ok)")
        } else {
            print("ax raise     : skipped（请在系统设置→隐私与安全性→辅助功能里允许 zcode-pet 后重试）")
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in NSApp.terminate(nil) }
    }
}

// MARK: - main

if CommandLine.arguments.contains("--jump-test") {
    let app = NSApplication.shared
    let delegate = JumpTestDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

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
