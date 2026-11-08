# Skill Source

個人 skills 的唯一來源。每個上游 repository 以 Git submodule 放在 `sources/<source-name>`，主 repo 固定來源版本；`.gitmodules` 的 `branch` 設定記錄上游分支。可載入的 skill 則以 `skills/<skill-name>` symlink 指向來源 repo 中含有 `SKILL.md` 的目錄。

## 管理 sources

使用管理腳本查看、加入、移除或更新來源 repo：

```sh
./scripts/submodules.sh list
./scripts/submodules.sh add mattpocock-skills https://github.com/mattpocock/skills.git main
./scripts/submodules.sh pull mattpocock-skills
./scripts/submodules.sh remove mattpocock-skills
```

若 `sources/<name>` 已經是 origin URL 相同且工作目錄乾淨的 Git clone，`add` 會直接把它登記成 submodule，不會重新下載。

`pull` 不會替主 repo commit；更新後需檢查並提交新的 submodule 指標。`remove` 會先檢查來源有沒有未提交內容，並要求確認。`sync` 會依主 repo 固定的 submodule 版本初始化來源並同步 skill links，但不會安裝全域 symlink。

## 手動管理 skills

```sh
git submodule add -b <upstream-branch> <repository-url> sources/<source-name>
./scripts/sync-skill-links.sh
```

來源 repo 可以在根目錄提供一個 skill，也可以是包含多個 skills 的集合。同步腳本會為來源中非隱藏目錄內的 `SKILL.md` 建立平坦 skill links；`in-progress/` 目錄會略過。若不同來源有同名 skill，後加入的來源會以來源名稱作前綴建立 link，例如 `pm-skills-retro`，保留原有 skill 名稱。新增後提交 `.gitmodules`、submodule 指標與 `skills/` symlinks。

Graphify 的上游使用 `skill-codex.md` 和平台專屬 references，不是標準 `SKILL.md`。同步腳本會把 Codex 版複製成一般檔案 `skills/graphify/SKILL.md`，並連結 Codex references；更新 Graphify submodule 後再執行同步腳本即可更新 adapter。

例如 `mattpocock/skills` 是 skill 集合，不是單一 skill repo；它的 skills 位於 `skills/engineering/<name>`、`skills/productivity/<name>` 等子目錄。加入來源並執行同步後，個別 skill 才會出現在 `skills/<name>`。

移除來源時，使用 `git rm sources/<source-name>` 從主 repo 移除 submodule 記錄，再執行 `./scripts/sync-skill-links.sh` 清除失效的 skill links。只刪除來源資料夾不會自動刪除 `.gitmodules` 記錄或 symlink。

## 安裝

```sh
./install.sh
```

安裝器會初始化來源 submodules、切到 `.gitmodules` 指定的分支、補上新 skill links，並把 `~/.agents/skills` 和 `~/.claude/skills` 連到本 repo 的 `skills/`。若目標路徑已存在，安裝器會列出內容並要求確認後才移除。

初版使用整個集合目錄的 symlink。若 Claude 無法載入該目錄，依設計再加入逐 skill symlink 與 macOS LaunchAgent 監看器。

## 更新

在 `sources/<source-name>` 執行 `git pull`，skill 會立即透過 symlink 使用更新後的檔案。接著回到此 repo 提交更新後的 submodule 指標，讓其他電腦也能取得相同版本：

```sh
git add sources/<source-name>
git commit -m "chore: update <source-name>"
```

其他電腦更新主 repo 後，執行安裝器即可。它使用 `git submodule update --merge`，保留來源 repo 分支並合併主 repo 記錄的版本：

```sh
git pull
./install.sh
```

`install.sh` 會初始化 submodules，並將 checkout 切到各自記錄的分支；它不會替主 repo 自動 commit 或 push。
