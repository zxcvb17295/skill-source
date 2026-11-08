# ADR 0001：來源 repo 與可載入 skills 分開管理

## 狀態

已採用

## 背景

上游 repository 不一定只包含一個 skill，也不一定把 `SKILL.md` 放在 repository 根目錄。`mattpocock/skills` 就是在同一個 repository 內維護多個位於不同子目錄的 skills。把整個 repository 直接放進 `skills/<name>`，會讓 Agent 看見來源專案目錄，而不是各個 skill 目錄。

## 決策

- 上游 repository 以 Git submodule 放在 `sources/<source-name>`。
- `skills/<skill-name>` 是指向來源中含有 `SKILL.md` 目錄的 symlink。
- `scripts/sync-skill-links.sh` 會為來源中非隱藏目錄內的 skills 建立 symlink，略過路徑包含 `in-progress` 的項目；同名 skill 發生衝突時停止，不覆寫既有項目。
- 全域 Agent/Claude 目錄指向 `skills/`，而非來源 repository。

## 後果

一個上游 repository 可提供一個或多個 skills，並保留原始 Git 歷史。新增上游 skill 後再次執行安裝器即可補上 link。每個來源 repository 的 submodule 指標仍由 Skill Source 固定與提交。
