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
| 開發環境本體(meta) | `dev-env-v3/`(本 repo) | 方法論 `RELIABLE_WORKFLOW.md`、build-log tickets(`v3-xxx`)、本文件、**Decision Ledger**(`.claude/ledger/`,跨 session 決策記憶、append-only;SessionStart 注入「過去否定了什麼+為何」治 decision drift,見 `tickets/v3-008.md`) | 跨專案,版控 |
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

---

## 9. 部署這套環境(quickstart / 跨平台)

> 這套 harness(plan-gate / handoff / session-start 注入 / context gauge)現在可以
> 一鍵裝到任何新機器。來源 = 私有 repo `bjchen-pixel/dev-env`。
> 安裝器核心是 `install.sh`(純 bash 3.2);Windows 入口 `install.ps1` 是薄殼,只負責
> 找到 Git Bash 再轉呼 `install.sh`。**冪等**——隨時可安全重跑。

### 9.0 兩種模式

| 模式 | 範圍 | 做什麼 | 何時 |
|---|---|---|---|
| **A — 機器層** | `~/.claude/`(user-level) | 把全域 statusLine(context gauge)接進 `~/.claude/settings.json`,指向本機 clone 的 `statusline/context-gauge.sh` | **每台機器一次** |
| **B — 專案層** | 目標 repo 的 `.claude/` | `--adopt <repo>`:把 `hooks/` + `templates/policy.json` 複製進目標 repo,並把三個 workflow hook(SessionStart / PreToolUse Edit\|Write / Stop)接進它的 `.claude/settings.json` | **每個目標專案一次** |

模式 B 的 hook 命令用 `bash "$(git rev-parse --show-toplevel)/hooks/..."`,路徑由目標 repo
自解析——搬動 repo 仍可用,零硬編碼。hook 機制細節見 `INSTALL.md`。

> **plan-gate 預設 = `enforce`(strict-by-default,2026-06-21 起)**。clone 到任何機器、零設定,
> PreToolUse gate 就有牙:**沒有 Approved plan 不准編輯實作檔**(擋下=exit 2,workflow surface
> `*.md`/`plans/`/`.claude/`/`.ai/` 永遠放行)。**逃生閥永遠在最上層**:`export V3_EDIT_PLAN_GATE=off`
> (或 `=advice` 只勸不擋)瞬間解除;或把 `templates/policy.json`(value=`advice`)丟進
> `<repo>/.ai/harness/policy.json` 軟回 advice。主權在甲方,機器只能擋不能宣判。
>
> **注意**:模式 A 的 statusLine(context gauge)目前只活在終端機、打不到 VS Code 主面板
> (見 `tickets/v3-006.md`),面板呈現待後續 companion 擴充;statusLine 為終端機備援。

### 9.1 取得來源(clone)

SSH(需該機器有 GitHub SSH key):
```sh
git clone git@github.com:bjchen-pixel/dev-env.git
```
HTTPS(免 SSH key):
```sh
git clone https://github.com/bjchen-pixel/dev-env.git
```

### 9.2 Mac / Linux quickstart

```sh
cd dev-env
./install.sh            # 先跑 preflight,再進互動選單(選 a / b / both / q)
```

非互動旗標(可組合):

| 指令 | 作用 |
|---|---|
| `./install.sh --auto` | 無人值守:自動同意可選依賴安裝;**無模式旗標時不進選單**(明示 `--mode-a`/`--adopt`/`--update`) |
| `./install.sh --mode-a` | 只做模式 A(機器層 statusLine merge) |
| `./install.sh --adopt <repo>` | 只做模式 B(把 guard 採用進 `<repo>`,須為 git repo) |
| `./install.sh --preflight-only` | 只跑依賴檢查報告然後退出 |
| `./install.sh --update` | `git pull --ff-only` 後冪等重套模式 A(見 §9.6) |
| `./install.sh --help` | 列出所有旗標 |

`--auto` 亦可與模式旗標併用,例:`./install.sh --mode-a --auto`。

### 9.3 Windows quickstart

Windows 上 Claude Code 的 hook 命令是**透過 Git Bash 執行**的,所以同一套 bash hook
不需改寫——但**必須先裝 Git for Windows(含 Git Bash)**:

1. 裝 Git for Windows(安裝時確保含 "Git Bash"):<https://git-scm.com/download/win>
2. clone(SSH 或 HTTPS,見 §9.1)。
3. 在 **PowerShell** 進到 repo 跑:
   ```powershell
   ./install.ps1
   ```
   `install.ps1` 會:(a) 偵測 `bash.exe`;(b) 設使用者環境變數
   `CLAUDE_CODE_GIT_BASH_PATH` 指向它;(c) 透過該 Git Bash 轉呼 `install.sh`,
   並把你給的旗標原樣轉傳(如 `./install.ps1 --mode-a --auto`、
   `./install.ps1 --adopt 'C:\path\to\repo'`)。
4. 設了環境變數後,**開新 terminal 並重啟 Claude Code** 才會生效。

**為什麼需要 Git Bash**:Claude Code 在 Windows 把 hook 命令字串交給 Git Bash 執行
(Git Bash 不在才退回 PowerShell)。因為我們要求 Git Bash,既有
`bash "$(git rev-parse --show-toplevel)/hooks/..."` 的 `$(...)` 會照常展開,hook 不必
為 Windows 重寫。`install.ps1` 設 `CLAUDE_CODE_GIT_BASH_PATH` 是為了強迫 Claude Code
用 Git Bash 跑 hook(而非 cmd 或找不到完整路徑的裸 `bash`)。

> **install.ps1 為 best-effort,需在 Windows 實機驗證**(本套件在 macOS 開發、無
> PowerShell,ps1 無法在此自動測)。請在 Windows 確認三步:偵測 bash、設 env、轉呼
> install.sh。核心 `install.sh` + `lib/*.sh` 已由 116 條 bash 測試覆蓋。

#### CRLF / LF 注意(Windows 必讀)

Git for Windows 預設 `core.autocrlf=true` 會把 `.sh` checkout 成 CRLF,讓 Git Bash 找
`bash\r` 失敗、**hook 靜默失效**。本 repo 已加 `.gitattributes`(`*.sh text eol=lf`)鎖
LF。**若你在加 `.gitattributes` 之前就已 clone**,需重新正規化一次:

```sh
git add --renormalize .
# 或更徹底地重抓:
git rm --cached -r .
git reset --hard
```

#### 萬一 ps1 沒設成功 env 變數(手動設法)

```powershell
[Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'C:\Program Files\Git\bin\bash.exe', 'User')
```
(路徑換成你機器上 `bash.exe` 的實際位置;設完開新 terminal / 重啟 Claude Code。)

### 9.4 依賴(preflight 自動檢查)

跑 `install.sh` 第一步是 preflight 依賴分層報告:

| 依賴 | 分層 | 缺了怎麼辦 |
|---|---|---|
| `git` | **必要** | bootstrap 工具,**不代裝**;印官方連結並停 |
| `bash` | **必要** | 正在跑代表已存在(Windows 經 Git Bash 提供) |
| `jq` | **可選** | 偵測到套件管理器 → **徵同意**安裝;**不裝也照跑**(有 awk fallback / 降級印片段) |
| Claude Code | **只偵測** | 前提工具,**不裝**;缺則報 missing + 印連結,不擋 |

缺可選依賴的安裝一律**徵同意**(印出將執行的指令、問 y/N);`--auto` 跳過確認。
**不靜默 escalate 權限**——`sudo` 之類會出現在印給你看的指令字串裡。

### 9.5 更新

```sh
./install.sh --update
```
= `git pull --ff-only` 更新本 clone + 冪等重套模式 A(已最新則 no-op)。
模式 B 的目標 repo **不被追蹤**;對每個採用過的 repo 自行:
```sh
git -C <repo> pull && ./install.sh --adopt <repo>   # adopt 冪等,重跑安全
```

**冪等性**:`install.sh` / `--adopt` / `--update` 都可安全重跑——不重複注入 hook、
不洗掉你既有設定;寫 user-level / 目標 settings 前先備份(`.bak.<UTC>`)。

### 9.6 一鍵回滾

**模式 A**(機器層):刪 `~/.claude/settings.json` 的 `statusLine` 鍵,或還原安裝時的
`~/.claude/settings.json.bak.<UTC>` 備份。重啟 Claude Code。其他鍵不受影響。

**模式 B**(專案層):還原目標 repo 的 `.claude/settings.json`
(`git -C <repo> checkout .claude/settings.json`,或還原其 `.bak.<UTC>`),並刪掉複製進去
的 `hooks/` + `templates/policy.json`。只動目標 repo 內,不碰 user-level。

**更輕的 kill switch**(不卸載、只停用)見 `INSTALL.md` §4:
- `export V3_EDIT_PLAN_GATE=off`(環境變數,最高優先,瞬間停 plan gate)
- `.claude/settings.json` 設 `{ "disableAllHooks": true }`(官方全域停用該 repo 所有 hook)

### 9.7 種入使用者層(`user-config/`)

`user-config/` 是「通用協作層」runtime 檔的版控備份(見 §2)。全新機器 clone 後,
`~/.claude/` 還沒有這些檔,Claude Code 讀不到三角分工/TDD 紀律與 agent 定義——
把它們從 `user-config/` 種進 `~/.claude/`:

| repo 內(來源) | 種到(目標) |
|---|---|
| `user-config/CLAUDE.md` | `~/.claude/CLAUDE.md` |
| `user-config/agents/engineer-tdd.md` | `~/.claude/agents/engineer-tdd.md` |
| `user-config/agents/verifier.md` | `~/.claude/agents/verifier.md` |

Windows(PowerShell)目標為 `C:\Users\<你>\.claude\...`(`agents\` 子目錄若無先建)。

手動複製(Mac/Linux):
```sh
mkdir -p ~/.claude/agents
cp user-config/CLAUDE.md     ~/.claude/CLAUDE.md
cp user-config/agents/*.md   ~/.claude/agents/
```

> **注意**
> - `user-config/` 在 **public** repo——只放可公開的協作方法論 / agent 規格,
>   密鑰、私人路徑等機敏資訊**絕不**放這裡。
> - 上面 `cp` 會覆蓋同名檔,**只在缺這些檔的新機器(如 Windows)執行**;
>   Mac 是源頭,別反向蓋回去。
> - 後續會由 `install.sh` 自動化此步,採 **copy-if-absent**(目標已存在則跳過、不覆蓋)。
