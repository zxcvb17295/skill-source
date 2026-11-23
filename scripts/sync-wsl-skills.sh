#!/usr/bin/env bash
# 在 WSL 內執行：把 skill-source 的 sources/ 與 skills/ 鏡像到 Linux 檔案系統，
# 並讓 ~/.agents/skills 指向鏡像，避免 Codex 啟動時跨 /mnt/c 掃描（實測慢 2~3 分鐘）。
#
#   ./scripts/sync-wsl-skills.sh            同步並切換 ~/.agents/skills
#   ./scripts/sync-wsl-skills.sh --dry-run  只預覽
#   ./scripts/sync-wsl-skills.sh --restore  還原為切換前的 ~/.agents/skills
#
# 鏡像位置可用 SKILL_SOURCE_WSL_DIR 覆寫，預設 ~/.local/share/skill-source。
# skill-source 有更新（pull、新增或移除 skill）後重跑即可，鏡像會以 --delete 同步。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
dest="${SKILL_SOURCE_WSL_DIR:-$HOME/.local/share/skill-source}"
entry="$HOME/.agents/skills"
dry_run=false
# WSL 原生 Claude 的 skills 目錄（.zshrc 以 ~/.claude-<acct> 當 CLAUDE_CONFIG_DIR）。
# 這些目錄另有 Claude 自己管理的 synced/，所以逐個 skill 連結，不整個換掉。
read -r -a claude_dirs <<< "${CLAUDE_SKILL_DIRS:-$HOME/.claude-sub/skills $HOME/.claude-api/skills}"

fail() { printf '錯誤：%s\n' "$1" >&2; exit 1; }

# 移除 Claude skills 目錄中指向鏡像、但鏡像已沒有該 skill 的連結；all=1 時全部移除。
prune_claude_links() {
  local all="$1" dir link
  for dir in "${claude_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for link in "$dir"/*; do
      [[ -L "$link" && "$(readlink "$link")" == "$dest/skills/"* ]] || continue
      if [[ "$all" == 1 || ! -e "$link" ]]; then rm "$link"; fi
    done
  done
}

link_claude_skills() {
  local dir skill name n
  for dir in "${claude_dirs[@]}"; do
    mkdir -p "$dir"
    n=0
    for skill in "$dest/skills"/*; do
      name="${skill##*/}"
      [[ "$name" != synced && -f "$skill/SKILL.md" ]] || continue
      if [[ -e "$dir/$name" && ! -L "$dir/$name" ]]; then
        printf '略過 %s：已有非連結的同名項目\n' "$dir/$name" >&2
        continue
      fi
      ln -sfn "$skill" "$dir/$name"
      n=$((n + 1))
    done
    printf '已連結 %s 個 skills 到 %s\n' "$n" "$dir"
  done
  prune_claude_links 0
}

restore() {
  prune_claude_links 1
  printf '已移除 Claude skills 目錄中指向鏡像的連結\n'

  local backup
  backup="$(ls -1d "$entry".bak-* 2>/dev/null | sort | tail -n 1 || true)"
  [[ -n "$backup" ]] || fail "找不到 $entry.bak-* 備份"
  [[ -L "$entry" && "$(readlink "$entry")" == "$dest/skills" ]] \
    || fail "$entry 不是指向鏡像的 symlink，不自動還原"
  rm "$entry"
  mv "$backup" "$entry"
  printf '已還原 %s -> %s\n' "$entry" "$(readlink "$entry" 2>/dev/null || echo '(目錄)')"
  printf '鏡像 %s 保留未刪，不需要時可自行移除。\n' "$dest"
}

case "${1:-}" in
  --dry-run) dry_run=true ;;
  --restore) restore; exit 0 ;;
  '') ;;
  *) fail "未知參數：$1" ;;
esac

[[ "$(uname -r)" == *[Mm]icrosoft* ]] || fail "此腳本只供 WSL 使用"
[[ -d "$repo_root/sources" && -d "$repo_root/skills" ]] || fail "找不到 $repo_root/sources 或 skills"
command -v rsync >/dev/null || fail "需要 rsync（sudo apt install rsync）"
case "$dest" in /mnt/*) fail "鏡像必須在 Linux 檔案系統，不能是 $dest" ;; esac

rsync_opts=(-a --delete --exclude=.git)
$dry_run && rsync_opts+=(-n --itemize-changes)

mkdir -p "$dest"
rsync "${rsync_opts[@]}" "$repo_root/sources/" "$dest/sources/"
rsync "${rsync_opts[@]}" "$repo_root/skills/" "$dest/skills/"

if $dry_run; then
  printf '預覽完成，未變更任何檔案。\n'
  exit 0
fi

# Windows Junction 在 WSL 看起來是指向 /mnt/c/... 的絕對 symlink，改指向鏡像。
# 比對不分大小寫，因為 /mnt/c 路徑大小寫不敏感。
root_lc="${repo_root,,}/"
while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  if [[ "${target,,}" == "$root_lc"* ]]; then
    ln -sfn "$dest/${target:${#root_lc}}" "$link"
  fi
done < <(find "$dest/skills" -type l -print0)

# 驗收：鏡像內所有 symlink 都要解析在鏡像內，且不可失效。
bad=0
while IFS= read -r -d '' link; do
  resolved="$(readlink -f "$link" || true)"
  if [[ -z "$resolved" || ! -e "$resolved" || "$resolved" != "$dest"/* ]]; then
    printf '連結異常：%s -> %s\n' "$link" "$(readlink "$link")" >&2
    bad=1
  fi
done < <(find "$dest" -type l -print0)
[[ $bad == 0 ]] || fail "鏡像內有連結指向鏡像外或已失效，未切換 $entry"

if [[ -L "$entry" && "$(readlink "$entry")" == "$dest/skills" ]]; then
  :
elif [[ -e "$entry" || -L "$entry" ]]; then
  backup="$entry.bak-$(date +%Y%m%d-%H%M%S)"
  mv "$entry" "$backup"
  printf '原入口已改名為 %s（還原：%s --restore）\n' "$backup" "$0"
  ln -s "$dest/skills" "$entry"
else
  mkdir -p "$(dirname "$entry")"
  ln -s "$dest/skills" "$entry"
fi

link_claude_skills

count="$(find -L "$dest/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l)"
printf '已同步 %s 個 skills：%s -> %s\n' "$count" "$entry" "$dest/skills"
