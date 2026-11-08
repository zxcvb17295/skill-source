#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
skills_dir="$repo_root/skills"
agent_skills="$HOME/.agents/skills"
claude_skills="$HOME/.claude/skills"

fail() {
  printf '錯誤：%s\n' "$1" >&2
  exit 1
}

plan_target() {
  local target="$1"

  if [[ -L "$target" ]]; then
    local current
    current="$(readlink "$target")"
    if [[ "$current" == "$skills_dir" ]]; then
      target_action=keep
      return 1
    fi
    printf '目標是指向其他位置的 symlink：%s -> %s\n' "$target" "$current"
  elif [[ -e "$target" ]]; then
    printf '即將移除現有路徑：%s\n' "$target"
    if [[ -d "$target" ]]; then
      ls -la "$target"
    fi
  else
    target_action=create
    return 0
  fi

  local answer
  read -r -p '確認移除並建立 Skill Collection symlink？輸入 yes 繼續：' answer
  [[ "$answer" == 'yes' ]] || fail "使用者取消；未變更 $target"
  target_action=replace
  return 0
}

prepare_submodules() {
  if [[ ! -f "$repo_root/.gitmodules" ]]; then
    return
  fi

  git -C "$repo_root" submodule sync --recursive
  git -C "$repo_root" submodule update --init --recursive --merge

  while IFS=' ' read -r key path; do
    [[ -n "${key:-}" && -n "${path:-}" ]] || continue
    [[ "$path" == sources/* && "$path" != *'/../'* ]] || fail "submodule 必須位於 sources/ 下：$path"

    local name branch module_dir commit
    name="${key#submodule.}"
    name="${name%.path}"
    branch="$(git -C "$repo_root" config -f .gitmodules --get "submodule.$name.branch" || true)"
    [[ -n "$branch" ]] || fail "submodule '$name' 尚未在 .gitmodules 設定 branch"
    git check-ref-format --branch "$branch" >/dev/null || fail "無效的上游分支名稱：$branch"
    [[ "${path#sources/}" != */* && "${path#sources/}" != '..' ]] || fail "每個來源 repo 必須直接位於 sources/ 下：$path"

    module_dir="$repo_root/$path"
    [[ -d "$module_dir" ]] || fail "submodule 尚未初始化：$path"
    [[ -z "$(git -C "$module_dir" status --porcelain)" ]] || fail "submodule 有未提交變更或未追蹤檔案，請先處理：$path"

    commit="$(git -C "$module_dir" rev-parse HEAD)"
    git -C "$module_dir" fetch origin "$branch"
    git -C "$module_dir" show-ref --verify --quiet "refs/remotes/origin/$branch" || fail "找不到上游分支 origin/$branch：$path"

    if [[ "$(git -C "$module_dir" branch --show-current)" == "$branch" ]]; then
      :
    elif git -C "$module_dir" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$module_dir" switch "$branch"
    else
      git -C "$module_dir" switch -c "$branch" "$commit"
    fi
    git -C "$module_dir" branch --set-upstream-to="origin/$branch" "$branch"
  done < <(git -C "$repo_root" config -f .gitmodules --get-regexp '^submodule\..*\.path$' || true)
}

link_collection() {
  local target="$1" action="$2"
  mkdir -p "$(dirname "$target")"
  case "$action" in
    replace) rm -rf "$target" ;;
    keep) return ;;
  esac
  if [[ "$action" != keep ]]; then
    ln -s "$skills_dir" "$target"
  fi
  printf '已設定 %s -> %s\n' "$target" "$skills_dir"
}

[[ -d "$repo_root/.git" ]] || fail "請從 Skill Source Git repository 執行此安裝器"
prepare_submodules
"$repo_root/scripts/sync-skill-links.sh"
[[ -d "$skills_dir" ]] || fail "找不到 skills/ 目錄"
has_skill=false
for skill_file in "$skills_dir"/*/SKILL.md; do
  if [[ -f "$skill_file" ]]; then
    has_skill=true
    break
  fi
done
[[ "$has_skill" == true ]] || fail "目前沒有可安裝的 skill。請先執行 ./scripts/submodules.sh add <name> <repo-url> [branch] 加入含 SKILL.md 的來源，再執行 install.sh"

plan_target "$agent_skills" || true
agent_action="$target_action"
plan_target "$claude_skills" || true
claude_action="$target_action"
link_collection "$agent_skills" "$agent_action"
link_collection "$claude_skills" "$claude_action"
printf '安裝完成。\n'
