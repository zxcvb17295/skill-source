#!/usr/bin/env bash
# 找出這台電腦的 Obsidian vault，印出絕對路徑（一行）。
# 順序：環境變數 OBSIDIAN_VAULT → Obsidian 的 obsidian.json（只有一個 vault 就用它；
# 有多個時用目前開著的，其次最近開過的）。
# 有多個候選時，其餘候選以「# 其他 vault：」開頭印到 stderr，方便確認有沒有選錯。
# 找不到時不印任何東西，exit 1。
set -uo pipefail

to_unix() {  # Windows 路徑（C:\Users\...）在 Git Bash 裡轉成 /c/Users/...
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}

if [ -n "${OBSIDIAN_VAULT:-}" ]; then
  v=$(to_unix "$OBSIDIAN_VAULT")
  [ -d "$v" ] && { printf '%s\n' "$v"; exit 0; }
  echo "# OBSIDIAN_VAULT 指向的資料夾不存在：$v" >&2
  exit 1
fi

for cfg in "$HOME/Library/Application Support/obsidian/obsidian.json" \
           "${APPDATA:+$(to_unix "$APPDATA")/obsidian/obsidian.json}" \
           "$HOME/.config/obsidian/obsidian.json"; do
  [ -n "$cfg" ] && [ -f "$cfg" ] || continue
  list=$(jq -r '.vaults | to_entries | sort_by(if .value.open then 0 else 1 end, -(.value.ts // 0))
                | .[].value.path' "$cfg" 2>/dev/null | tr -d '\r') || continue
  first=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    u=$(to_unix "$p")
    [ -d "$u" ] || continue
    if [ -z "$first" ]; then first="$u"; else echo "# 其他 vault：$u" >&2; fi
  done <<< "$list"
  [ -n "$first" ] && { printf '%s\n' "$first"; exit 0; }
done
exit 1
