# zcode-pet — ZCode 桌面宠物 🐾

给 [ZCode](https://z.ai) 做的桌面宠物（灵感来自 Codex 宠物）：屏幕角落一只悬浮宠物实时反映任务状态，**任务完成/出错由宠物本体直接提示**（庆祝/报错动画 + 常驻未读角标），不发系统通知、不打断当前工作。

```
😸 3 个任务执行中…          ← 有任务在跑（浮动动画）
🎉 任务完成！               ← 刚完成（5 秒庆祝动画）
😿 任务出错了 ⚠️            ← 有任务失败（颤抖动画）
😺 休息中 💤 · 5 未读       ← 空闲，还有 5 条完成结果没看
```

菜单栏 `🐾 N 📬M`：N = 执行中任务数，M = 未读完成数。下拉可看清单（**点击直达对应工作区**）、切换 7 款皮肤，**全部矢量动画**、同一套设计语言（渐变身体/表情眼/嘴型/眨眼/呼吸/**眼神跟随**/打呵欠）——球球、饭团（海苔）、菱菱（菱形+腮红）、蛋蛋（呆毛）、咪咪（猫耳+摇尾）、兔兔（长耳）、幽幽（幽灵，波浪裙边+悬浮）；执行中/完成/出错四种状态换情绪体色与表情。形象画法参考 emotion-ball（角色原作者 sam70331），角色设计为原创。

## 功能

| 场景 | 表现 |
|---|---|
| 有任务执行中（含定时/自动化任务） | 悬浮宠物干活动画 + 菜单栏计数 |
| 任务完成 | 🎉 宠物庆祝动画 5 秒 + 菜单栏 `📬M` 未读角标 |
| 任务出错 | 😿 颤抖动画 + `📬M` 未读角标 |
| 点击宠物 | 弹出任务清单（执行中/完成未读，**点击直达对应工作区**）；**按住可拖动**，位置自动记忆 |
| 未读完成 | 菜单栏 `📬M` 计数 + 「N 未读」文案常驻，直到在 ZCode 里看过 |

## 安装（macOS，两步）

**前置要求**：macOS 13+、已安装 ZCode 桌面版、Xcode Command Line Tools（编译守护进程用，没有的话先跑 `xcode-select --install`）。

### 第 1 步：安装宠物守护进程

```bash
git clone https://github.com/kylinzhao/zcode-pet.git
cd zcode-pet
bash scripts/install.sh
```

脚本会：编译 Swift 守护进程到 `~/.zcode-pet/zcode-pet.app` → 注册开机自启（LaunchAgent）→ 立即启动并自检。屏幕右下角出现宠物即成功。

### 第 2 步：安装 ZCode 插件（hook 事件源）

1. 打开 ZCode → **设置 → Plugin Marketplace → Add → Add Plugin Marketplace**
2. 粘贴本仓库地址：`kylinzhao/zcode-pet`（或克隆后的本地路径 `<你的路径>/zcode-pet`）
3. **个人 → zcode-pet → zcode-pet 桌面宠物 → Install**

### 第 3 步：重启一次 ZCode

插件安装前已打开的会话不会加载插件的 hook（宠物看不到它们在干活），重启 ZCode 后全部生效。之后新建的会话无需任何操作。

### 验证

随便在 ZCode 里发一条消息：宠物应立即变 😸 显示"1 个任务执行中…"；回合结束后宠物跳一段庆祝动画、菜单栏出现 `📬1`。

## 日常使用

- **点宠物** = 弹任务清单（再点条目直达工作区）；**按住拖动** = 挪位置（自动记忆）
- **菜单栏 🐾**：执行中/未读清单（点击直达）、宠物造型（7 款皮肤，矢量家族带缩略图）、Stop hook 心跳、退出
- **改配置**（可选）：`~/.zcode-pet/config.json`

```json
{
  "pollInterval": 2,
  "zcodeAppBundleId": "dev.zcode.app"
}
```

## 故障排查

| 症状 | 处理 |
|---|---|
| 宠物不显示执行中任务 | 宠物靠插件 hook 感知回合开始——确认插件已安装且 **ZCode 重启过**（旧会话需重载插件）；菜单栏看 "Stop hook 心跳" 是否 ✗ |
| 想看自检 | `~/.zcode-pet/zcode-pet.app/Contents/MacOS/zcode-pet-daemon --test` |
| 看日志 | `tail -f ~/.zcode-pet/daemon.log` |
| 手动重启守护进程 | `launchctl kickstart -k gui/$UID/dev.zcode.pet` |

## 卸载

```bash
bash scripts/uninstall.sh      # 停守护进程 + 移除 LaunchAgent（~/.zcode-pet 数据目录保留）
```
再在 ZCode 设置里卸载 zcode-pet 插件即可。

## 架构（60 秒版）

```
~/.zcode/v2/tasks-index.sqlite ──2s 只读轮询──▶ 宠物守护进程（Swift/AppKit，单文件）
zcode-pet 插件 hook 三件套 ──events.jsonl────▶ ~/.zcode-pet/zcode-pet.app
SessionStart/LaunchAgent ────双通道保活──────▶ 悬浮宠物 + 菜单栏
```

核心数据模型（实测逆向得出）：

- **执行中**以插件 hook 事件为准（`UserPromptSubmit`=回合开始，`Stop`=回合结束）。
  ZCode 的 `task_status='running'` 只在任务首轮为真，不能当执行中信号。
- **未读完成** = `unread_at IS NOT NULL`（live 标记）。
- **完成确认** = turn_end 事件后延迟 4s 查库终态（completed/error），另有首轮状态翻转兜底。
  不能用 `updated_at` 变化当完成信号——用户点击任务列表也会 bump 它。
- **点击跳转** = `zcode://workspace/open?path=<工作区>`（ZCode 唯一可用的深链，无任务级深链）。

## 已知限制

- 依赖 ZCode 的非公开接口（sqlite schema、hook 事件），ZCode 大版本升级后若失效，先跑 `--test`。
- 只监控办公实例（`dev.zcode.app`）；双开的个人实例未接入。
- 任务点击跳到的是**所属工作区**（ZCode 无任务级深链），完成任务会在侧栏未读高亮。

## 开发

```bash
bash scripts/install.sh    # 改 daemon/main.swift 后重跑即重新编译部署
```

- 守护进程：`daemon/main.swift`（Swift/AppKit 单文件，皮肤表 `petSkins`、轮询状态机）
- 插件：`plugins/zcode-pet/`（SessionStart 拉起守护进程、UserPromptSubmit/Stop 转发回合事件）
- **球球一族**（`animated` 皮肤）：纯矢量 CoreGraphics 绘制（`PetArt.drawVector`），不走资产；
  由 12fps tick 逐帧重绘实现眨眼（6~14s 随机、过冲回弹）、呼吸（±1%）、嘴型（微笑/抿嘴/大笑/撇嘴）
  与**眼神跟随**（读全局鼠标，视向平滑逼近；贴近 ~90pt 内瞳孔微放大，>380pt 转为慢速漫游）。
  idle 每隔 22~34s 打一次呵欠（张嘴挤眼 2.6s）。形状家族沿其 blob/wedge/gem 三体型思路：球球（圆）、
  饭团（圆角三角 + 海苔）、菱菱（超椭圆 n=1.4 菱形 + 腮红）、蛋蛋（竖椭圆 + 呆毛 + 腮红）。
  基础画法参数参考 [emotion-ball-desktop-pet](https://github.com/dreamcall520/emotion-ball-desktop-pet)
  网页演示的渲染源码独立实现（角色原作者 sam70331，免费非商用需署名）；
  矢量皮肤可 `--render-art /tmp/pet-art` 导出 PNG 自检

MIT License
