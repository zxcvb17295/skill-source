#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
  printf '錯誤：%s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：./scripts/submodules.sh <command> [arguments]

commands:
  list                              列出已註冊的 sources
  add <name> <url> [branch]         加入 source（branch 預設 main）
  remove <name> [--yes]             移除 source 與其 skill links
  pull [name|all]                   拉取上游分支；省略時更新全部 sources
  sync                              對齊主 repo 記錄的 submodule 版本並同步 skill links
EOF
}

require_repo() {
  [[ -f "$repo_root/.git" || -d "$repo_root/.git" ]] || fail "找不到 Skill Source Git repository"
}

source_section() {
  printf 'submodule.sources/%s' "$1"
}

source_branch() {
  git -C "$repo_root" config -f .gitmodules --get "$(source_section "$1").branch" || true
}

source_path() {
  git -C "$repo_root" config -f .gitmodules --get "$(source_section "$1").path" || true
}

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "source 名稱只能使用英數字、點、底線與連字號"
}

sync_skill_links() {
  "$repo_root/scripts/sync-skill-links.sh"
}

ensure_source_branch() {
  local name="$1" path="$2" branch="$3" module_dir current commit
  module_dir="$repo_root/$path"

  if [[ -e "$module_dir/.git" ]]; then
    [[ -z "$(git -C "$module_dir" status --porcelain)" ]] || fail "source 有未提交變更或未追蹤檔案，請先處理：$path"
  fi
  if [[ ! -e "$module_dir/.git" ]]; then
    git -C "$repo_root" submodule update --init --recursive --merge -- "$path"
  fi
  [[ -d "$module_dir" ]] || fail "source 尚未初始化：$path"
  [[ -z "$(git -C "$module_dir" status --porcelain)" ]] || fail "source 有未提交變更或未追蹤檔案，請先處理：$path"

  git -C "$module_dir" fetch origin "$branch"
  git -C "$module_dir" show-ref --verify --quiet "refs/remotes/origin/$branch" || fail "找不到上游分支 origin/$branch：$path"

  current="$(git -C "$module_dir" branch --show-current)"
  if [[ "$current" != "$branch" ]]; then
    if git -C "$module_dir" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$module_dir" switch "$branch"
    else
      commit="$(git -C "$module_dir" rev-parse HEAD)"
      git -C "$module_dir" switch -c "$branch" "$commit"
    fi
  fi
  git -C "$module_dir" branch --set-upstream-to="origin/$branch" "$branch"
}

list_sources() {
  local found=false key path name section branch url state
  if [[ ! -f "$repo_root/.gitmodules" ]]; then
    printf '目前沒有 source。\n'
    return
  fi

  printf '%-24s %-12s %-16s %s\n' 'NAME' 'BRANCH' 'STATUS' 'URL'
  while IFS=' ' read -r key path; do
    [[ -n "${key:-}" && -n "${path:-}" ]] || continue
    name="${path#sources/}"
    section="${key%.path}"
    branch="$(git -C "$repo_root" config -f .gitmodules --get "$section.branch" || true)"
    url="$(git -C "$repo_root" config -f .gitmodules --get "$section.url" || true)"
    if [[ -e "$repo_root/$path/.git" ]]; then
      state="initialized"
    else
      state="missing"
    fi
    printf '%-24s %-12s %-16s %s\n' "$name" "${branch:-?}" "$state" "${url:-?}"
    found=true
  done < <(git -C "$repo_root" config -f .gitmodules --get-regexp '^submodule\..*\.path$' || true)

  [[ "$found" == true ]] || printf '目前沒有 source。\n'
}

add_source() {
  local name="${1:-}" url="${2:-}" branch="${3:-main}" path module_dir existing_origin worktree_root
  [[ -n "$name" && -n "$url" ]] || { usage; exit 2; }
  validate_name "$name"
  git check-ref-format --branch "$branch" >/dev/null || fail "無效的 branch 名稱：$branch"
  path="sources/$name"
  [[ -z "$(source_path "$name")" ]] || fail "source 已存在：$path"

  module_dir="$repo_root/$path"
  if [[ -e "$module_dir" || -L "$module_dir" ]]; then
    [[ -d "$module_dir" && ( -e "$module_dir/.git" || -d "$module_dir/.git" ) ]] || fail "路徑已存在，但不是 Git clone：$path"
    worktree_root="$(git -C "$module_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ "$worktree_root" == "$module_dir" ]] || fail "既有 Git repository 的根目錄與 source 路徑不符：$path"
    existing_origin="$(git -C "$module_dir" remote get-url origin 2>/dev/null || true)"
    [[ "$existing_origin" == "$url" ]] || fail "既有 clone 的 origin 不符（目前：${existing_origin:-無 origin}）；請使用該 origin URL"
    [[ -z "$(git -C "$module_dir" status --porcelain)" ]] || fail "既有 clone 有未提交變更或未追蹤檔案，請先處理：$path"
    printf '採用既有 clone，不重新下載：%s\n' "$path"
  fi

  git -C "$repo_root" submodule add -b "$branch" "$url" "$path"
  sync_skill_links
  git -C "$repo_root" add -A -- skills
  printf '\n已加入 %s。檢查變更後提交主 repo：\n  git status\n  git commit -m %s\n' "$name" "\"feat: add $name skills\""
}

remove_source() {
  local name="${1:-}" answer="" path module_dir section
  [[ -n "$name" ]] || { usage; exit 2; }
  validate_name "$name"
  path="$(source_path "$name")"
  [[ -n "$path" ]] || fail "找不到 source：$name"
  module_dir="$repo_root/$path"
  section="$(source_section "$name")"

  if [[ -e "$module_dir/.git" ]]; then
    [[ -z "$(git -C "$module_dir" status --porcelain)" ]] || fail "source 有未提交變更或未追蹤檔案，請先處理：$path"
  fi

  printf '即將移除 source：%s (%s)\n' "$name" "$path"
  for link_path in "$repo_root/skills"/*; do
    [[ -L "$link_path" ]] || continue
    case "$(readlink "$link_path")" in
      "../$path"|"../$path/"*) printf '  skill: %s\n' "$(basename "$link_path")" ;;
    esac
  done
  if [[ "$name" == graphify && -f "$repo_root/skills/graphify/SKILL.md" ]]; then
    printf '  skill: graphify (Codex adapter)\n'
  fi

  if [[ "${2:-}" != '--yes' ]]; then
    read -r -p '確認移除？輸入 yes 繼續：' answer
    [[ "$answer" == yes ]] || fail "使用者取消；未移除 $name"
  fi

  git -C "$repo_root" rm -f -- "$path"
  if git -C "$repo_root" config -f .gitmodules --get "$section.path" >/dev/null 2>&1; then
    git -C "$repo_root" config -f .gitmodules --remove-section "$section"
  fi
  git -C "$repo_root" add -- .gitmodules
  sync_skill_links
  git -C "$repo_root" add -A -- skills
  printf '\n已移除 %s。檢查變更後提交主 repo。\n' "$name"
}

pull_source() {
  local name="$1" path branch module_dir
  path="$(source_path "$name")"
  [[ -n "$path" ]] || fail "找不到 source：$name"
  branch="$(source_branch "$name")"
  [[ -n "$branch" ]] || fail "source 未設定 branch：$name"
  ensure_source_branch "$name" "$path" "$branch"
  module_dir="$repo_root/$path"
  git -C "$module_dir" pull --ff-only origin "$branch"
  printf '已更新 source：%s\n' "$name"
}

sync_sources() {
  local key path name branch
  if [[ -f "$repo_root/.gitmodules" ]]; then
    git -C "$repo_root" submodule sync --recursive
    while IFS=' ' read -r key path; do
      [[ -n "${key:-}" && -n "${path:-}" ]] || continue
      [[ "$path" == sources/* && "${path#sources/}" != */* ]] || fail "source 必須直接位於 sources/ 下：$path"
      name="${path#sources/}"
      branch="$(source_branch "$name")"
      [[ -n "$branch" ]] || fail "source 未設定 branch：$name"
      ensure_source_branch "$name" "$path" "$branch"
    done < <(git -C "$repo_root" config -f .gitmodules --get-regexp '^submodule\..*\.path$' || true)
  fi
  sync_skill_links
}

require_repo
command="${1:-}"
shift || true

case "$command" in
  list)
    list_sources
    ;;
  add)
    add_source "${1:-}" "${2:-}" "${3:-main}"
    ;;
  remove)
    remove_source "${1:-}" "${2:-}"
    ;;
  pull)
    if [[ $# -eq 0 || "${1:-}" == all ]]; then
      while IFS=' ' read -r key path; do
        [[ -n "${key:-}" && -n "${path:-}" ]] || continue
        pull_source "${path#sources/}"
      done < <(git -C "$repo_root" config -f .gitmodules --get-regexp '^submodule\..*\.path$' || true)
    else
      pull_source "$1"
    fi
    sync_skill_links
    printf '上游更新完成；主 repo 的 submodule 指標尚未 commit。\n'
    ;;
  sync)
    sync_sources
    ;;
  help|-h|--help|'')
    usage
    ;;
  *)
    usage >&2
    fail "未知指令：$command"
    ;;
esac
