#!/usr/bin/env bash
# 收集某一天（台北時間）的日報素材，輸出純文字給 agent 讀。
# 用法：collect.sh [YYYY-MM-DD]，預設今天。macOS 的 bash 與 Windows 的 Git Bash 都能跑，需要 jq。
# 每台電腦可用環境變數調整：
#   OBSIDIAN_VAULT    vault 路徑（沒設定時由 obsidian-vault/vault-path.sh 從 Obsidian 設定找）
#   DAILY_REPO_ROOTS  要掃 git repo 的上層資料夾，用 : 分隔，預設 $HOME/Documents
set -uo pipefail
export TZ=CST-8  # POSIX 寫法的 UTC+8，macOS 與 Git Bash 都認得
LC_ALL=$(locale -a 2>/dev/null | grep -iE '^(en_US|C)\.utf-?8$' | head -1); export LC_ALL="${LC_ALL:-C}"

D="${1:-$(date +%F)}"
NEXT=$(date -d "$D +1 day" +%F 2>/dev/null || date -j -v+1d -f %F "$D" +%F)
HERE=$(cd "$(dirname "$0")" && pwd)
VERR=$(mktemp); VAULT=$(bash "$HERE/../obsidian-vault/vault-path.sh" 2>"$VERR")
IFS=: read -r -a ROOTS <<< "${DAILY_REPO_ROOTS:-$HOME/Documents}"
jqr() { jq "$@" | tr -d '\r'; }  # Windows 版 jq 會輸出 CRLF
MAX=300  # 每則訊息最多字數

# jq：UTC 時間字串 → 台北日期與時間
JQ_TPE='def tpe: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdate + 28800;
        def day: tpe | strftime("%Y-%m-%d");
        def hm:  tpe | strftime("%H:%M");
        def noise: test("^\\s*(<|# AGENTS\\.md|Base directory for this skill|Caveat:|\\[Request interrupted|This session is being continued)");'

section() { printf '\n## %s\n' "$1"; }

section "0. Vault 與日報設定"
if [ -n "$VAULT" ]; then
  echo "vault：$VAULT"
  cat "$VERR"
  dn="$VAULT/.obsidian/daily-notes.json"
  if [ -f "$dn" ]; then
    DFOLDER=$(jqr -r '.folder // ""' "$dn"); DFORMAT=$(jqr -r '.format // ""' "$dn"); DTPL=$(jqr -r '.template // ""' "$dn")
    echo "Daily notes 設定：folder=${DFOLDER:-（vault 根目錄）} format=${DFORMAT:-YYYY-MM-DD} template=${DTPL:-（無）}"
  else
    DFOLDER=""; echo "Daily notes 設定：沒有 .obsidian/daily-notes.json"
  fi
  [ -f "$VAULT/AGENTS.md" ] && echo "AGENTS.md：有" || echo "AGENTS.md：沒有"
  [ -d "$VAULT/Projects" ] && echo "Projects/：有" || echo "Projects/：沒有"
else
  echo "找不到 vault：設定環境變數 OBSIDIAN_VAULT，或確認 Obsidian 有開過 vault。第 3、4、7 段只會收到 repo 裡的資料。"
  cat "$VERR"
  DFOLDER=""
fi
rm -f "$VERR"

section "1. Git commit（${D}）"
for root in "${ROOTS[@]}"; do for r in "$root"/*/; do
  [ -d "$r/.git" ] || continue
  log=$(git -C "$r" log --all --since="$D 00:00" --until="$NEXT 00:00" \
        --format='%h %ad %s' --date=format:%H:%M 2>/dev/null)
  [ -n "$log" ] && printf '### %s\n%s\n' "$(basename "$r")" "$log"
done; done

section "2. 未 commit 的變更"
if [ "$D" = "$(date +%F)" ]; then
  for root in "${ROOTS[@]}"; do for r in "$root"/*/; do
    [ -d "$r/.git" ] || continue
    # 只列今天動過的檔案，略過放了很久的舊變更
    st=$(git -C "$r" status --short --untracked-files=normal 2>/dev/null | grep -v '\.DS_Store$' \
         | while IFS= read -r l; do p="${l:3}"; p="${p##* -> }"; p="${p%/}"
             [ -n "$(find "$r$p" -maxdepth 0 -newermt "$D" 2>/dev/null)" ] && echo "$l"; done)
    n=$(printf '%s' "$st" | grep -c .)
    ahead=$(git -C "$r" rev-list --count '@{u}..HEAD' 2>/dev/null)
    name=$(basename "$r")
    [ "$n" -gt 0 ] && printf '### %s（今天動過 %s 項）\n%s\n' "$name" "$n" "$(printf '%s\n' "$st" | head -15)"
    [ "$n" -gt 15 ] && echo "…其餘 $((n-15)) 項略過"
    [ "${ahead:-0}" -gt 0 ] && printf '### %s：%s 個 commit 尚未 push\n' "$name" "$ahead"
  done; done
else
  echo "（只在收集今天時檢查；過去日期略過）"
fi

section "3. EVENTS.log"
find "${ROOTS[@]}" ${VAULT:+"$VAULT/Projects"} -maxdepth 5 -name EVENTS.log 2>/dev/null | while read -r f; do
  out=$(jqr -r --arg d "$D" "$JQ_TPE"' select(.at and (.at|day)==$d)
        | "\(.at|hm) \(.event) \(.role // "")/\(.slug // "") \(.summary // "" | .[0:'$MAX'])"' "$f" 2>/dev/null)
  [ -n "$out" ] && printf '### %s\n%s\n' "${f#$HOME/}" "$out"
done

section "4. Vault 當天新增或修改的筆記"
[ -n "$VAULT" ] && find "$VAULT" -name '*.md' -newermt "$D" ! -newermt "$NEXT" -not -path '*/.obsidian/*' \
  | sed "s|^$VAULT/||" | sort

section "5. Claude Code 對話（使用者訊息）"
find "$HOME/.claude/projects" -name '*.jsonl' -newermt "$D" 2>/dev/null | while read -r f; do
  out=$(jqr -r --arg d "$D" "$JQ_TPE"'
        select(.type=="user" and (.isMeta|not) and .timestamp and (.timestamp|day)==$d)
        | (.message.content | if type=="string" then . else (map(select(.type=="text").text) | join(" ")) end) as $t
        | select(($t|length)>0 and ($t|noise|not))
        | "\(.timestamp|hm) [\(.cwd // "" | sub(env.HOME; "~"))] \($t | gsub("\\s+"; " ") | .[0:'$MAX'])"' "$f" 2>/dev/null)
  name=$(basename "$f" .jsonl); case "$name" in agent-*) name="${name}（subagent）";; esac
  [ -n "$out" ] && printf '### %s\n%s\n' "$name" "$out"
done

section "6. Codex 對話（使用者訊息與結尾回覆）"
find "$HOME/.codex/sessions" -name '*.jsonl' -newermt "$D" 2>/dev/null | while read -r f; do
  out=$(jqr -r --arg d "$D" "$JQ_TPE"'
        select(.timestamp and (.timestamp|day)==$d)
        | if .type=="session_meta" then "cwd: \(.payload.cwd | sub(env.HOME; "~"))"
          elif .type=="response_item" and .payload.role=="user" then
            (.payload.content | map(.text // "") | join(" ")) as $t
            | select(($t|length)>0 and ($t|noise|not))
            | "\(.timestamp|hm) 使用者：\($t | gsub("\\s+"; " ") | .[0:'$MAX'])"
          elif .type=="event_msg" and .payload.type=="task_complete" then
            "\(.timestamp|hm) Codex：\(.payload.last_agent_message // "" | gsub("\\s+"; " ") | .[0:'$MAX'])"
          else empty end' "$f" 2>/dev/null)
  echo "$out" | grep -qE '^[0-9]{2}:[0-9]{2} ' && printf '### %s\n%s\n' "$(basename "$f" .jsonl)" "$out"
done

section "7. 前一篇日報未完成的待處理"
# 檔名開頭是 YYYY-MM-DD 的筆記都算日報，日期取檔名前 10 個字
prev=""
[ -n "$VAULT" ] && prev=$(find "$VAULT/${DFOLDER}" -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.md' -not -path '*/.obsidian/*' 2>/dev/null \
       | awk -F/ -v d="$D" '{n=substr($NF,1,10); if (n<d) print n"\t"$0}' | sort | tail -1 | cut -f2)
if [ -n "$prev" ]; then
  echo "來源：${prev#$VAULT/}"
  tr -d '\r' < "$prev" | grep -E '^\s*- \[ \] *[^ ]' || echo "無"
else
  echo "無"
fi
