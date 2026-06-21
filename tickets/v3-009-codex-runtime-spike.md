# 工單 v3-009：Codex Runtime Spike

**狀態**：待 Codex 計畫書
**類型**：Spike（驗證驅動，非實作）
**執行**：工程師（Codex）— D2–D4 實測須在 Codex runtime 內進行
**文件查證（D1）**：可由 Opus/Sonnet 獨立佐證，降低受測者自評偏差
**Repo**：`/Volumes/Data 4T/Projects/dev-env-v3/`

---

## 1. 背景

dev-env-v3 目前只有 Claude Code adapter（`.claude/` + `hooks/`），其 plan gate 靠 `PreToolUse` hook 在寫檔前攔截、以 `exit 2` 阻擋。甲方計劃讓同一個 repo 同時支援 Codex，兩 runtime 共用方法論、隔離 runtime wiring。

但「把 Claude Code 的 hook schema 平移到 Codex」是**未驗證假設**。據初步查閱，Codex 宣稱讀 `AGENTS.md`、有 `.codex/config.toml` 與 `hooks.json`、文件列出 `SessionStart / PreToolUse / Stop` 與 `matcher`、`type = "command"`、`PreToolUse` 支援 `apply_patch`。**以上各條列為 pending verification，須由 D1 以官方文件 URL 逐條證實後方可採信。** 此外，尚未證實兩件決定性的事：

1. Codex hook 的非零 exit code 是否真能**阻擋**寫檔（vs 警告放行 vs 純記錄）。
2. Codex hook 的 stdin payload 結構，是否與 Claude Code 的 `.tool_input.file_path` 相容。

這兩點未證實前，Codex 側的 `enforce` plan gate 不能承諾，現有 `pre-edit-guard.sh` 能否共用也是未知。

本工單目的：**先證明地板在哪，再蓋房子。** 跑完後產出可據以決策的證據，而非「好像可以」。

## 2. 設計原則

- 這是 spike，**不是** runtime 實作。不新增 `core/`、不升格 `.codex/`、不改動現有 `.claude/` 與 `hooks/`。
- 所有測試材料隔離在拋棄式路徑（`.codex-spike/` 或 `/tmp`），驗證完即可刪。
- 不污染共享狀態層：不寫 `.ai/harness/active-plan`、不寫 `.ai/harness/handoff/resume.md`。
- 結論必須可證偽。exit code 語意以 **side effect（目標檔是否真的被改）** 判定，不以 hook/process 回傳值自我宣稱判定。
- payload 相容性以**真實樣本原文**判定，不以官方文件描述推測。

## 3. 交付項目

### D1：官方文件摘要

Codex hooks 機制的事實基礎，需附出處（URL + 段落）：

- hook schema：支援的事件名、`matcher` 語法、`type = "command"` 的執行契約。
- config 載入位置與優先序（`.codex/config.toml`、`hooks.json` 各自角色）。
- trust requirement：repo 需滿足什麼條件，hooks 才會被載入執行。
- 官方對 hook exit code / stdout / stderr 行為的**任何明文描述**（若無，明確標注「官方未載明，待實測」）。

### D2：基礎觸發證據

在 spike repo 實測並附證據（log / 終端輸出 / 檔案落地）：

- `AGENTS.md` 是否在 Codex 於此 repo 啟動時被讀取。
- `SessionStart`、`PreToolUse`、`Stop` 三個 hook 是否真的觸發（各附觸發證據）。
- 每個 hook 觸發時機點（startup / resume / 寫檔前 / 結束）的實際對應。

### D3：exit code 三態實驗（硬驗收，見 §5-A）

產出對照結果，判定 Codex `PreToolUse` 非零 exit 的真實語意。

### D4：stdin payload 對照表（硬驗收，見 §5-B）

產出 Claude Code vs Codex 並排對照表，判定能否共用現有 guard。

### D5：結論裁決

基於 D1–D4，結論**只能**落在三者之一：

1. **enforce 可行**：Codex 可做與 Claude Code 等價的機械阻擋 plan gate。
2. **僅 advice**：Codex 非零 exit 不阻擋，只能做警告 / logging，plan gate 無法機械強制。
3. **需獨立 adapter**：Codex payload / 生命週期差異過大，不能共用現有 guard，需重寫解析層。

裁決需指出落點理由，並列出該落點下「下一刀」的建議切片。

## 4. Codex 計畫書需回答的問題

1. spike repo 怎麼準備？用 dev-env-v3 本體開分支，還是另開乾淨 throwaway repo？（傾向後者，避免污染；請說明選擇）
2. Codex 如何在本機取得並啟動？版本號為何？trust 怎麼設定才能讓 hooks 載入？
3. D3 的 exit code 實驗，你打算對「哪個目標檔」觸發 guard？如何確保該 edit **必定**會路由到你的 `PreToolUse` hook（否則測不到攔截）？
4. 如何擷取 D4 的真實 stdin payload 原文？（例如 hook 內 `cat > /tmp/codex-payload.json`）你怎麼確認擷取到的是完整 payload 而非截斷？
5. 若 Codex 根本不觸發 `PreToolUse`，或觸發但 payload 為空，你的 fallback 觀測手段是什麼？
6. 證據如何留存？log 路徑、檔案命名、貼進 ticket 的格式。

計畫書經老師批改（必修 / 建議 / 否決）通過後才動工。

## 5. 驗收標準

### A. exit code 三態實驗（side effect 判定）

**必須以目標檔是否被實際修改判定，不接受只看 hook/process exit 回傳值。**

實驗矩陣，至少涵蓋：

| 案例 | hook 回傳 | 預期觀測點 | 判定 |
|---|---|---|---|
| A1 | `exit 0` | 目標檔內容 | 應被改（基準對照組） |
| A2 | `exit 1` | 目標檔內容 + agent 是否收到訊息 | 待測 |
| A3 | `exit 2` | 目標檔內容 + agent 是否收到訊息 | 待測 |

每個案例必須記錄三項 side effect：

- **目標檔是否真的被改**（diff before/after，或 hash 比對）——這是主判據。
- agent 端是否收到任何阻擋 / 警告訊息（stdout/stderr 是否回灌）。
- hook 自身的 exit 值（僅作交叉參考，**不作主判據**）。

三態映射規則（驗收時據此歸類）：

- 目標檔**未變** → **block**。
- 目標檔**已變**且 agent 收到警告 → **warn-through**。
- 目標檔**已變**且 agent 無感 → **log-only**。

**驗收門檻**：`exit 1` 與 `exit 2` 各自的歸類必須明確落在 block / warn-through / log-only 之一，且附 before/after 證據。若 `exit 2` 判為 block → enforce 有地板；若兩者皆非 block → enforce 不可行。**不接受「看起來有擋」這類無 side effect 證據的結論。**

### B. stdin payload 對照表

產出下表，Codex 欄位必須填**真實擷取的原文欄位名**（非官方文件推測值）：

| 欄位 | Claude Code | Codex（實測） | 是否相容 |
|---|---|---|---|
| target file path | `.tool_input.file_path` | ？ | ？ |
| tool / 操作名稱 | （現有 guard 解析值） | `apply_patch`？ | ？ |
| diff / content | ？ | ？ | ？ |
| cwd / 工作目錄 | ？ | ？ | ？ |
| session / 識別 | ？ | ？ | ？ |

**驗收門檻**：

- 附**完整 Codex payload 原文樣本**（D4 擷取的 raw JSON 或等價物），不只填表格。
- 「是否相容」欄需明確結論：**現有 `pre-edit-guard.sh` 的解析邏輯能否直接吃 Codex payload**。
- 若 target path 取法不同（欄位名 / 巢狀層級不同，或 Codex 只給 patch diff 而不給 file path）→ 必須標注「需重寫解析層」，並導向 §3-D5 結論 3。

### C. 整體

- D1–D5 全數交付，每項證據可追溯（出處 URL 或本機 log 路徑）。
- D5 裁決明確落在三結論之一，無模稜兩可。
- 所有 spike 產物隔離於拋棄式路徑，未動 `.claude/`、`hooks/`、`.ai/harness/` 共享狀態。

## 6. 不在範圍

- **不**實作 Codex runtime adapter（不建正式 `.codex/`、不寫正式 hooks）。
- **不**新增 `core/` 抽象層或任何 schema 文件。
- **不**改動現有 Claude Code adapter（`.claude/`、`hooks/`）。
- **不**合併或共寫 handoff / active-plan;Codex 若需 handoff 一律走獨立路徑。
- **不**做 install 腳本的 `--mode-codex` / `--mode-both`;那是 spike 證明 enforce 可行後的後續工單。
- **不**承諾任何 enforce 行為;本工單只負責回答「能不能 enforce」。
