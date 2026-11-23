#!/usr/bin/env bash
# 找出這台電腦的 team-state 資料夾（多 agent 協作的 lead 入口），印出絕對路徑（一行）。
# 順序：環境變數 TEAM_STATE_DIR → ~/Documents/team-state。
# 認得的條件：資料夾裡有 AGENT.md。找不到時不印任何東西，exit 1。
set -uo pipefail

to_unix() {  # Windows 路徑（C:\Users\...）在 Git Bash 裡轉成 /c/Users/...
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}

if [ -n "${TEAM_STATE_DIR:-}" ]; then
  d=$(to_unix "$TEAM_STATE_DIR")
  [ -f "$d/AGENT.md" ] && { printf '%s\n' "$d"; exit 0; }
  echo "# TEAM_STATE_DIR 指向的資料夾沒有 AGENT.md：$d" >&2
  exit 1
fi

for d in "$HOME/Documents/team-state" \
         "${USERPROFILE:+$(to_unix "$USERPROFILE")/Documents/team-state}"; do
  [ -n "$d" ] && [ -f "$d/AGENT.md" ] && { printf '%s\n' "$d"; exit 0; }
done
exit 1
