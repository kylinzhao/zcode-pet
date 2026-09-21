# zcode-pet 插件

ZCode 桌面宠物的插件侧：只负责把回合生命周期事件转发给宠物守护进程
（`~/.zcode-pet/bin/zcode-pet-daemon`），并在守护进程不在时拉起它。

## 组件

- `hooks/hooks.json` — 三件套：
  - `SessionStart`（`startup|resume`）：拉起守护进程（LaunchAgent 通常已在跑，兜底）
  - `UserPromptSubmit`：推"回合开始"事件（宠物在 DB 落库前 ~2s 就切忙碌）
  - `Stop`：推"回合结束"事件（兼作 Stop hook 活性心跳，菜单栏可查）
- `hooks/pet_hook.sh` — 事件写入 `~/.zcode-pet/events.jsonl`；契约：不阻塞、不输出 JSON、
  永不 block、软失败静默（不阻塞、不输出、永不 block、软失败静默）。

## 依赖

守护进程需先安装：仓库根目录 `bash scripts/install.sh`（编译 + LaunchAgent 开机自启）。
插件单独安装时事件只是累积，守护进程起来后自动追上。
