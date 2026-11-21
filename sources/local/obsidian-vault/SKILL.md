---
name: obsidian-vault
description: 使用者的 Obsidian 知識庫：個人筆記、專案設計概覽與 handoff、技術速查。Use when 要把內容記錄或整理成筆記、寫 handoff 或每日概要，或要查以前的筆記、專案決策與技術紀錄。
---

# Obsidian 知識庫

Vault 路徑：`$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Access`
（`~/Documents/Obsidian` 是指向它的 symlink；工具權限以實際路徑為準）

## 0. 確認 vault 存在

先 `ls` 上面的實際路徑。不存在時，告訴使用者這台電腦沒有 Obsidian 知識庫，然後回到原本的任務；只在 vault 存在時繼續下面的步驟。

## 查詢

1. 用 `rg` 搜尋標題與內文關鍵字；入口是 `知識庫首頁.md`。
2. 在程式 repo 裡工作時，先找 `Projects/<repo 名稱>/`。資料夾名稱可能和 repo 不同（例如 repo `ai-team-state` 對應 `Projects/ai-team/`），找不到就用 `rg` 搜 repo 名稱。找到後先讀 `設計概覽.md` 與日期最新的 handoff。

完成條件：已列出相關筆記的路徑，或確認沒有相關筆記。

## 寫入

使用者要求記錄時直接寫入，不必再確認。

1. 完整讀 vault 根目錄的 `AGENTS.md`。位置、模板、標籤與完成檢查都以它為準。
2. 寫出草稿。要寫每日概要（每日日誌、當天回顧）時，照 [daily.md](daily.md) 收集與撰寫。內容屬於某個專案時，同一次也更新 `Projects/<專案>/設計概覽.md` 的 `updated`、現況、下一步與決策紀錄。
3. 載入 `humanizer` skill，用它的 file mode 修順每一篇新增或改寫的筆記。只改敘述文字；frontmatter、程式碼、指令、路徑、表格資料與 `[[wikilink]]` 保持原樣，所有事實、數字與日期都要留住。這台電腦沒有 `humanizer` 時照常寫入，回報時說明。
4. 照 `AGENTS.md` 的「完成檢查」逐項確認，最後回報新增或修改的筆記路徑。

完成條件：每篇筆記都通過 `AGENTS.md` 完成檢查，Humanizer 找出的 AI 腔調都已改掉或說明保留原因。

## 範圍

- 只新增或修改 `.md` 筆記；刪除、搬移或改名前先告知使用者。
- Vault 由 iCloud 同步，剛寫入的檔案可能稍後才出現在其他裝置。
