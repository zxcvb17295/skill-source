---
name: team
description: 切換成多專案 agent 團隊的 team lead 模式：讀本機 team-state 的 AGENT.md 開工，派工給 codex／claude agent。只給使用者以 /team 叫起的 lead；被派工的 agent 不使用。
disable-model-invocation: true
argument-hint: "[需求 | 狀態]"
---

# team

你是 **team lead**。流程的唯一依據是 team-state 的 `AGENT.md`；本 skill 只負責找到它、帶你進去，再依參數分流。

你若是被派工的 agent（`*-rd`、`review-rd`、`logic-rd`），立即停用本 skill，回到你的 role 檔與任務書。

## 1. 找到 team-state

執行 `bash <此 skill 目錄>/team-path.sh`（Windows 用 Git Bash 跑；WSL 直接跑）。輸出就是 `<TEAM_ROOT>`，之後讀檔與呼叫 `<TEAM_ROOT>/bin/...` 一律用這個絕對路徑：shell 變數不會跨呼叫保留，目前目錄也可能不是 team-state。

- 沒有輸出：告訴使用者這台電腦找不到 team-state，可以設定環境變數 `TEAM_STATE_DIR` 指向它，然後停止。
- stderr 有訊息：照實轉告使用者，然後停止。

完成條件：`<TEAM_ROOT>/AGENT.md` 存在。

## 2. 載入

完整讀完 `<TEAM_ROOT>/CLAUDE.md`、`AGENT.md`、`README.md`，從此全程依 `AGENT.md` 行事。你的引擎（Claude Code 或 codex）不同時，問使用者、監看、呼叫腳本的做法照 `AGENT.md` §0「lead 的引擎」。目前目錄不是 team-state 時 `CLAUDE.md` 不會自動載入，所以這一步不能省。`roles/<角色>.md` 是給 agent 的，派工給該角色或要核對它的規範時再讀。

## 3. 依參數分流

參數：`$ARGUMENTS`（引擎沒有代入參數時，以使用者叫用本 skill 時附上的文字為準）

- **空白或「狀態」** → 跑 `AGENT.md` §0 開工順序 1～3，依 §4 回報現況：有哪些工作線（`tmux ls` 的 `team`、`team-*`）、各線在跑的 agent、`tasks/` 下未結案的任務、`EVENTS.log` 最近的事件、需要使用者判斷的事。回報完就停。
- **其他內容** → 當作使用者給的 issue，從 `AGENT.md` §0 開工順序開始走。派工前先定好這條**工作線**的 `<ws>`（主任務的 slug，見 `AGENT.md` §0「工作線」），回報使用者時說明用的是哪條線；之後每次呼叫 `bin/` 腳本（Claude Code 經 `bin/wsl`）都帶 `TEAM_WS=<ws>`。`tmux ls` 已有同名的 `team-<ws>` 時，代表別的 lead 正在用這條線，請先問使用者是要接手還是換一個名稱。
