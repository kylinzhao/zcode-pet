# zcode-pet — ZCode 桌面宠物 🐾

给 [ZCode](https://z.ai) 做的桌面宠物（灵感来自 Codex 宠物）：屏幕角落一只悬浮宠物实时反映任务状态，**任务完成/失败即时系统通知，点击通知直接跳回该任务**。

```
😸 3 个任务执行中…          ← 有任务在跑（浮动动画）
😺 休息中 💤 · 5 未读       ← 空闲，还有 5 条完成结果没看
🎉 任务完成！               ← 刚完成（5 秒庆祝动画）
😿 任务出错了 ⚠️            ← 有任务失败（颤抖动画 + 必须点掉的弹窗）
```

菜单栏 `🐾 N 📬M`：N = 执行中任务数，M = 未读完成数。下拉可看清单（**点击直达对应工作区**）、切换 17 款皮肤——14 款 emoji（猫/狗/熊猫/企鹅/火箭/机器人/幽灵…）+ 3 款手绘（**樱木花道、恐龙、白兵**：MiniMax image-01 生成的贴纸风立绘，四种状态各一个姿势，像素画作离线兜底）、静音。

## 功能

| 场景 | 表现 |
|---|---|
| 有任务执行中（含定时/自动化任务） | 悬浮宠物干活动画 + 菜单栏计数 |
| 任务完成 | 🎉 + 即时系统通知（任务标题 + 耗时 + 音效），**点通知跳回该任务所属工作区** |
| 任务出错 | 😿 + 即时通知 + 红边弹窗（必须点掉） |
| 全部归零（长任务 ≥2 分钟） | 绿边"全部任务完成，等你回来审核"弹窗 |
| 点击宠物 | 跳回 ZCode；**按住可拖动**，位置自动记忆 |
| 未读完成 | 菜单栏 `📬M` 计数 + 菜单清单（✅/⚠️，点击直达） |

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
4. 首次启动会弹"**zcode-pet 想给你发送通知**"——点**允许**（点击通知跳转任务依赖它）

### 第 3 步：重启一次 ZCode

插件安装前已打开的会话不会加载插件的 hook（宠物看不到它们在干活），重启 ZCode 后全部生效。之后新建的会话无需任何操作。

### 验证

随便在 ZCode 里发一条消息：宠物应立即变 😸 显示"1 个任务执行中…"；回合结束后（切到其他应用时）收到 🐾 通知，点通知跳回该任务。

## 日常使用

- **点宠物** = 跳回 ZCode；**按住拖动** = 挪位置（自动记忆）
- **菜单栏 🐾**：执行中/未读清单（点击直达）、宠物造型（17 款皮肤）、静音 30 分钟、Stop hook 心跳、退出
- **改配置**（可选）：`~/.zcode-pet/config.json`

```json
{
  "pollInterval": 2,
  "notifyCooldown": 10,
  "allClearMinSeconds": 120,
  "zcodeAppBundleId": "dev.zcode.app"
}
```

## 故障排查

| 症状 | 处理 |
|---|---|
| 宠物不显示执行中任务 | 宠物靠插件 hook 感知回合开始——确认插件已安装且 **ZCode 重启过**（旧会话需重载插件）；菜单栏看 "Stop hook 心跳" 是否 ✗ |
| 收不到通知 | 系统设置 → 通知 → zcode-pet → 允许；重装后可能需要重新允许 |
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
SessionStart/LaunchAgent ────双通道保活──────▶ 悬浮宠物 + 菜单栏 + UN 通知 + 分级弹窗
```

核心数据模型（实测逆向得出）：

- **执行中**以插件 hook 事件为准（`UserPromptSubmit`=回合开始，`Stop`=回合结束）。
  ZCode 的 `task_status='running'` 只在任务首轮为真，不能当执行中信号。
- **未读完成** = `unread_at IS NOT NULL`（live 标记）。
- **完成确认** = turn_end 事件后延迟 4s 查库终态（completed/error），另有首轮状态翻转兜底。
  不能用 `updated_at` 变化当完成信号——用户点击任务列表也会 bump 它。
- **点击跳转** = `zcode://workspace/open?path=<工作区>`（ZCode 唯一可用的深链，无任务级深链）。

## 已知限制

- 依赖 ZCode 的非公开接口（sqlite schema、hook 事件、深链），ZCode 大版本升级后若失效，先跑 `--test`。
- 只监控办公实例（`dev.zcode.app`）；双开的个人实例未接入。
- 通知点击跳到的是任务**所属工作区**（ZCode 无任务级深链），完成任务会在侧栏未读高亮。

## 开发

```bash
bash scripts/install.sh    # 改 daemon/main.swift 后重跑即重新编译部署
```

- 守护进程：`daemon/main.swift`（Swift/AppKit 单文件，皮肤表 `petSkins`、轮询状态机、UN 通知）
- 插件：`plugins/zcode-pet/`（SessionStart 拉起守护进程、UserPromptSubmit/Stop 转发回合事件）
- **手绘皮肤**：优先级 = 图片资产 > 像素画 > emoji。图片资产在 `daemon/assets/pet/<skin>-<mode>.png`
  （512² 透明底贴纸，mmx image-01 生成：品红底出图 → 泛洪抠底 → 裁切），install.sh 拷入 bundle
  `Resources/pet-art/`；像素画为 26×17 字符矩阵（`PetArt`），改完可
  `~/.zcode-pet/zcode-pet.app/Contents/MacOS/zcode-pet-daemon --render-art /tmp/pet-art`
  导出 PNG 自检（含行宽校验）

MIT License
