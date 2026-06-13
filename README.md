# V3 開發環境:架構與用法

> 通用 AI 協作開發環境。本檔是這套環境的「設計 + 怎麼用」說明,跨專案共用。
> 詳細工作流協定見 `RELIABLE_WORKFLOW.md`(同 repo)。
> 維護原則:手寫精簡,勿 AI 膨脹。建立:2026-06-13。

## 1. 這是什麼
把「甲方 + 老師 + 工程師」三角協作收斂進單一 Claude Code 環境,讓 orchestrator
原生 dispatch、觀測 worker 執行,取代跨工具手動複製貼上。長期持續迭代的工程。

## 2. 三層架構(東西放哪)
| 層 | 位置 | 放什麼 | 範圍 |
|---|---|---|---|
| 通用協作層(runtime) | `~/.claude/` | `CLAUDE.md`(三角/TDD/context 紀律 + orchestrator 護欄)、`agents/engineer-tdd.md`、`agents/verifier.md`、`SETUP_NOTES.md` | 所有專案繼承 |
| 開發環境本體(meta) | `dev-env-v3/`(本 repo) | 方法論 `RELIABLE_WORKFLOW.md`、build-log tickets(`v3-xxx`)、本文件 | 跨專案,版控 |
| 專案脈絡 | `<專案>/.claude/CLAUDE.md` | 該專案專屬(如 InvestSys:moomoo / equity-only / 路徑) | 單一專案 |

Claude Code 啟動時自動合併「通用層 + 當前專案層」。
- **runtime 一定要在 `~/.claude/`**——Claude Code 才讀得到。
- **絕不 symlink `~/.claude/` 到外接 4TB**——碟沒掛載就整個斷。

## 3. 角色與模型
| 角色 | 是誰 | 做什麼 | 模型 |
|---|---|---|---|
| 甲方 | 人 | 提需求、最終決策、逃生閥 | — |
| 老師 / orchestrator | Opus | 垂直切片劃分、寫工單/規格、批改、驗收 | Opus |
| 工程師 / worker | `engineer-tdd` subagent | red-green-refactor 執行、commit、回報 | Sonnet |
| 驗收者 | `verifier` subagent | 查測試是否真在驗行為(非只看綠燈),唯讀 | Sonnet |

**模型配難度**:orchestration/推理用 Opus,執行用 Sonnet。別拿 Opus 或 Mythos 級(Fable 5)做搬檔、謄文件這種機械活。

## 4. 怎麼跑一個任務(主迴圈)
1. **甲方**提需求。
2. **老師**劃分垂直切片 + 寫工單(背景/設計原則/交付/計畫書要答的問題/驗收標準/不在範圍)。← 固定人工關卡在「切片劃分」。
3. **工程師**讀工單,回計畫書 v1(逐題回答,給實際環境事實)。
4. **老師**批改(必修/建議/否決)。過了才動工。
5. **工程師**執行:red(先親眼看到失敗)→ green(最小實作)→ refactor,tiny commits。
6. **verifier**查核:測試是真行為測試還是 implementation-fitted?抓得到 bug 嗎?涵蓋邊界/失敗路徑嗎?
7. **老師**驗收:對驗收標準逐條 + 獨立核實證據(不橡皮圖章)。

何時跳過工單:單純 `mv`/查資料/改個字 → 直接做。有 plan/測試/驗收的實質交付 → 才走工單。

## 5. 鐵律
- **垂直切片**:每片端到端可驗證(薄)。禁止水平切片。
- **TDD**:一次一行為;red 必先親眼看到失敗才寫實作;嚴禁同步生成 test + 實作。只用在「可立即驗證的程式行為」,不套用投資 thesis 這種延遲回饋層。
- **Context**:壓 ~100k 以下;clear 勝過 compact;clear 前 orchestrator 產出交接。
- **驗收靠證據不靠自述**:字面輸出(`git status`/`ls`/pytest red+green/`cat`);verifier 靜態查假測試是主力,不是 git 紅燈。
- **orchestrator 不自己寫實作**:統一環境裡老師有 Write/Bash,但實作一律 dispatch 給 `engineer-tdd`;老師輸出限於切片/規格/批改/驗收/交接。

## 6. 啟動驗證(換新 session,或改過 `~/.claude/` 後)
runtime 在 session 啟動時載入,改了要重啟。在**目標專案根目錄**開新 session:
1. `/memory` → 確認同時載入使用者級 + 專案級兩份 `CLAUDE.md`。
2. 行為探針:問「老師能不能自己寫實作碼?」→ 應答「不行,dispatch 給 engineer-tdd」。
3. `/agents` 看到 `engineer-tdd`/`verifier` → 指名 dispatch trivial 任務 → 確認 spawn + system prompt 正確。

## 7. tickets 放哪
- 開發環境本身的 build-log ticket(`v3-xxx`)→ `dev-env-v3/tickets/`。
- 各專案的功能 ticket → `<專案>/.claude/tickets/`。

## 8. 現況(2026-06-13)
runtime(`~/.claude/`)已建好、啟動驗證 3/3 過、跑過第一刀 TDD 切片(`_classify_mfi`)。
但日常工作流還沒切換,仍用「網頁版 Opus ↔ 手動轉貼 ↔ Sonnet」接力。
北極星 = Opus 在 Claude Code 裡原生接手 orchestration。本文件 + 碟上 tickets/CLAUDE.md,
是讓那個接棒接得住的載體。
