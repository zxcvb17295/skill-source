#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
sources_dir="$repo_root/sources"
skills_dir="$repo_root/skills"

fail() {
  printf '錯誤：%s\n' "$1" >&2
  exit 1
}

[[ -d "$sources_dir" ]] || fail "找不到 sources/ 目錄"
mkdir -p "$skills_dir"

# Generated skill links are separate filesystem entries from their source
# submodules. Remove only generated links whose source target has disappeared.
for link_path in "$skills_dir"/*; do
  [[ -L "$link_path" ]] || continue
  link_target="$(readlink "$link_path")"
  case "$link_target" in
    ../sources/*)
      if [[ ! -e "$link_path" ]]; then
        rm "$link_path"
        printf '已移除失效 skill link：%s\n' "$(basename "$link_path")"
      fi
      ;;
  esac
done

found=false
while IFS= read -r skill_file; do
  [[ -n "$skill_file" ]] || continue
  skill_dir="$(dirname "$skill_file")"
  case "$skill_dir/" in
    */in-progress/*) continue ;;
  esac

  skill_name="$(basename "$skill_dir")"
  source_rel="${skill_dir#"$repo_root"/}"
  link_target="../$source_rel"
  link_path="$skills_dir/$skill_name"
  found=true

  if [[ -e "$link_path" || -L "$link_path" ]]; then
    if [[ -L "$link_path" && "$(readlink "$link_path")" == "$link_target" ]]; then
      continue
    fi
    if [[ -L "$link_path" ]]; then
      existing_target="$(readlink "$link_path")"
      case "$existing_target" in
        ../sources/*)
          existing_source="${existing_target#../sources/}"
          existing_source="${existing_source%%/*}"
          target_source="${link_target#../sources/}"
          target_source="${target_source%%/*}"
          if [[ "$existing_source" == "$target_source" ]]; then
            rm "$link_path"
            ln -s "$link_target" "$link_path"
            printf '已修正 skill link：%s -> %s\n' "$skill_name" "$link_target"
            continue
          fi
          alias_path="$skills_dir/$target_source-$skill_name"
          if [[ -L "$alias_path" && "$(readlink "$alias_path")" == "$link_target" ]]; then
            continue
          fi
          [[ ! -e "$alias_path" && ! -L "$alias_path" ]] || fail "skill 名稱衝突，來源前綴名稱也已使用：$alias_path"
          ln -s "$link_target" "$alias_path"
          printf '已加入來源前綴 skill：%s -> %s\n' "$(basename "$alias_path")" "$link_target"
          continue
          ;;
      esac
    fi
    fail "skill 名稱衝突或已有非自動 symlink：$link_path"
  fi

  ln -s "$link_target" "$link_path"
  printf '已加入 skill：%s -> %s\n' "$skill_name" "$link_target"
done < <(find "$sources_dir" -type d \( -name '.*' -o -name node_modules \) -prune -o -type f -name SKILL.md -print)

# Graphify publishes separate skill files per platform instead of SKILL.md.
# Materialize its Codex variant so the skill manifest is a regular file.
graphify_source="$sources_dir/graphify/graphify"
if [[ -f "$graphify_source/skill-codex.md" ]]; then
  graphify_dir="$skills_dir/graphify"
  [[ ! -L "$graphify_dir" ]] || fail "Graphify adapter 路徑必須是目錄：$graphify_dir"
  mkdir -p "$graphify_dir"

  graphify_manifest="$graphify_dir/SKILL.md"
  if [[ -L "$graphify_manifest" ]]; then
    unlink "$graphify_manifest"
  elif [[ -e "$graphify_manifest" && ! -f "$graphify_manifest" ]]; then
    fail "Graphify adapter 的 SKILL.md 不是一般檔案：$graphify_manifest"
  fi
  cp "$graphify_source/skill-codex.md" "$graphify_manifest"

  graphify_references="$graphify_dir/references"
  if [[ -L "$graphify_references" ]]; then
    unlink "$graphify_references"
  elif [[ -e "$graphify_references" ]]; then
    fail "Graphify adapter references 已存在且不是 symlink：$graphify_references"
  fi
  ln -s "../../sources/graphify/graphify/skills/codex/references" "$graphify_references"
  printf '已同步 Codex Graphify adapter：%s\n' "$graphify_dir"
  found=true
else
  graphify_dir="$skills_dir/graphify"
  graphify_manifest="$graphify_dir/SKILL.md"
  graphify_references="$graphify_dir/references"
  if [[ -f "$graphify_manifest" && -L "$graphify_references" && \
        "$(readlink "$graphify_references")" == '../../sources/graphify/graphify/skills/codex/references' ]]; then
    unlink "$graphify_references"
    rm "$graphify_manifest"
    rmdir "$graphify_dir"
    printf '已移除失效的 Codex Graphify adapter。\n'
  fi
fi

if [[ "$found" != true ]]; then
  printf 'sources/ 中沒有可用 skill。\n'
fi
