---
name: obsidian-vault
description: 使用者的 Obsidian 知識庫：個人筆記、專案設計概覽與 handoff、技術速查。Use when 要把內容記錄或整理成筆記、寫 handoff，或要查以前的筆記、專案決策與技術紀錄。
---

# Obsidian 知識庫

## 0. 找到 vault

執行 `bash <此 skill 目錄>/vault-path.sh`（Windows 用 Git Bash 跑；需要 `jq`）。它依序看環境變數 `OBSIDIAN_VAULT` 和 Obsidian 自己的 vault 清單，印出這台電腦的 vault 路徑。以下的 `<vault>` 都指這個路徑，工具權限以它為準。

- 沒有輸出：告訴使用者這台電腦找不到 Obsidian 知識庫，可以設定 `OBSIDIAN_VAULT`，然後回到原本的任務。
- stderr 有「其他 vault」：這台電腦有多個 vault，腳本選了開著的那個。這次對話第一次用到時，向使用者確認選對了；選錯就請使用者設定 `OBSIDIAN_VAULT`。

每台電腦的 vault 結構可能不同。讀寫前先看 `<vault>` 根目錄有沒有 `AGENTS.md`、首頁筆記和 `Projects/`；下面提到的檔案或資料夾不存在時，就跳過那一步，改照 vault 裡既有筆記的資料夾、模板與 frontmatter 寫。

完成條件：已知 `<vault>` 路徑，也知道它有沒有 `AGENTS.md` 和 `Projects/`。

## 查詢

1. 用 `rg` 搜尋標題與內文關鍵字；有首頁筆記（例如 `知識庫首頁.md`）就從它開始。
2. 在程式 repo 裡工作時，先找 `Projects/<repo 名稱>/`。資料夾名稱可能和 repo 不同（例如 repo `ai-team-state` 對應 `Projects/ai-team/`），找不到就用 `rg` 搜 repo 名稱。找到後先讀 `設計概覽.md` 與日期最新的 handoff。

完成條件：已列出相關筆記的路徑，或確認沒有相關筆記。

## 寫入

使用者要求記錄時直接寫入，不必再確認。

1. 完整讀 `<vault>/AGENTS.md`，位置、模板、標籤與完成檢查都以它為準。沒有 `AGENTS.md` 時，先看同類筆記放在哪、用什麼 frontmatter，照著寫。
2. 寫出草稿。要寫日報（每日概要、當天回顧）時改載入 `daily` skill，由它收集與撰寫。內容屬於某個專案、且 vault 有 `Projects/<專案>/設計概覽.md` 時，同一次也更新它 的 `updated`、現況、下一步與決策紀錄。
3. 把草稿整理成原子筆記：一張卡片只講一件事，標題就是那件事，內文短到一眼讀完。
   - 寫到另一件事（另一個流程、測試資料、測試紀錄、SQL、決策）時，先用 `rg` 找 vault 有沒有現成的筆記；有就用 `[[連結]]` 指過去，沒有就另開一張卡片再連結。原處只留一句摘要和連結。
   - 要把內容加進既有筆記前，先確認它和那張卡片講的是同一件事；不是就另開一張。
   - 新卡片放在相關筆記的同一個資料夾；資料夾裡已有編號（例如 `10 測試-新增.md`），新卡片就照編號規則取名。
   - 同一個主題拆出好幾張卡片時，留一張總覽卡片列出各卡片的 `[[連結]]`，讓人從那裡進去。
4. 每一篇新增或改寫的筆記都要載入 `humanizer` skill，用它的 file mode 修過才算寫完，卡片、每日日誌、handoff、設計概覽都一樣。只改敘述文字；frontmatter、程式碼、指令、路徑、表格資料與 `[[wikilink]]` 保持原樣，所有事實、數字與日期都要留住。載入不到 `humanizer` 時先停下，請使用者執行 `skill-source` 的 `install.sh`，裝好後再寫入。
5. 照 `AGENTS.md` 的「完成檢查」逐項確認（沒有 `AGENTS.md` 就確認位置、標題與新增的 `[[wikilink]]` 都對），最後回報新增或修改的筆記路徑。

完成條件：每張新增或改寫的卡片只講一件事，其他相關內容都用 `[[wikilink]]` 連到別張卡片，連結目標都存在；每篇筆記都經過 `humanizer` 修改，也通過 `AGENTS.md` 完成檢查；Humanizer 找出的 AI 腔調都已改掉，或在回報時說明保留的原因。

## 範圍

- 只新增或修改 `.md` 筆記；刪除、搬移或改名前先告知使用者。
- Vault 若有雲端同步（iCloud、OneDrive、Obsidian Sync），剛寫入的檔案可能稍後才出現在其他裝置。
