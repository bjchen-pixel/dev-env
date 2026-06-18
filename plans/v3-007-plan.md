# v3-007 計畫書 — 跨平台一鍵部署器 + GitHub 備份（dev-env 可攜化）

**Status**: Approved
**工單**: `tickets/v3-007.md`
**作者**: 工程師 (engineer-tdd)
**日期**: 2026-06-17
**承**: `tickets/v3-005.md`（Plan-Gate + Handoff）、`tickets/v3-006.md`（Context Gauge）

---

**本回合交付**: 本計畫書（Draft）+ **僅 Slice 1（preflight / doctor）的逐 test red→green 增量**。停在 Slice 1 全綠,不碰 Slice 2（模式 A statusLine merge）。核准是老師職權,本計畫書 Status 維持 Draft。

---

## 0. 已查證的環境事實（影響規格,非臆測；動工前已親手驗證）

| 事實 | 來源 | 對規格的影響 |
|---|---|---|
| 本機 `/bin/bash` = **GNU bash 3.2.57(1)-release (arm64-apple-darwin25)** | `/bin/bash --version` | install.sh / lib/preflight.sh **禁** `declare -A` / `${var^^}` / `mapfile`/`readarray`;只用 bash 3.2 語法（沿用既有 `hooks/lib/*.sh` 慣例）。 |
| `jq` = **jq-1.7.1-apple**,`/usr/bin/jq` 存在 | `command -v jq` / `jq --version` | jq 列為**可選**依賴。所有 JSON 操作主路徑用 jq,**並備 awk fallback**;fallback 以「fresh-shell `command -v jq` 屏蔽」實測（沿用 v3-005 S5-4 手法,避開 command-hash 快取假陽性）。preflight 偵測到缺 jq → 問一下但**不擋**安裝。 |
| 既有 test runner = `tests/run.sh`,純 bash、零依賴,每 case 一函式,`$TESTS` 清單驅動,印 PASS/FAIL,FAIL 累加後 `exit 1` | 讀檔 | 新測試**沿用同一 runner**（直接擴充 `tests/run.sh` 的 helper + 新 test 函式 + `$TESTS` 清單）。不引入 bats。 |
| 既有 lib 慣例:狀態用 return code、資料用 stdout;jq 主路徑 + 窄目標 awk fallback;`pwd -P` canonical;`local IFS` 不外洩 | `hooks/lib/workflow-state.sh` | preflight 純函式沿用同一風格:偵測/分類函式回 return code + stdout,副作用（真跑安裝）獨立、與純函式分離。 |
| 本 repo 已 push `git@github.com:bjchen-pixel/dev-env.git`（SSH）,`main` 47 commit | 工單第二節 | Slice 0 完成;部署來源 = 此私有 repo。 |
| statusLine 掛 user-level `~/.claude/settings.json`,command 含寫死絕對路徑指向本機 clone 的 `statusline/context-gauge.sh` | `INSTALL.md` §7 | 模式 A（Slice 2,非本回合）要 merge 進既有 settings、保留其他鍵、先備份。本回合僅 preflight。 |
| 本 repo 目前**無** `.ai/harness/active-plan` marker | `cat .ai/harness/active-plan`（不存在） | 本 repo plan-gate 在 advice 模式（無 marker → 未核准 → advice 只警告不擋）。編輯 install.sh 時會見 `[PlanStatusGuard] advice:` 提醒,屬預期,不規避。 |

> 既有 `hooks/`、`statusline/`、`templates/`、`.claude/` 內**零**硬編碼絕對路徑（工單第二節已 grep 證實）；唯一要動態修正的路徑 = 模式 A 的 user-level statusLine 命令（Slice 2,非本回合）。

---

## 1. 目標與成功標準（對齊工單第一、七節）

**完工長相（全工單）**:在新機器上 `git clone <url> && ./install.sh`,部署器先跑 **preflight**（依賴分層報告:present/missing/版本）→ 缺必要依賴徵同意安裝（`--auto` 跳過確認）→ 互動選單選模式 A（機器層 statusLine）/ B（專案層 hooks）/ 兩者 → 冪等套用。`--update` = `git pull` + 冪等重套。Windows 入口 `install.ps1` 偵測 Git Bash 轉呼 install.sh。

**本回合（Slice 1）成功標準**:
- preflight 的**純函式層**（依賴偵測、版本抓取、套件管理器偵測、「缺某依賴該跑哪條安裝指令」的純對映）以 TDD 驅動,可在**不實際安裝**下斷言。
- 依賴分層正確:git/bash = **必要**;jq = **可選**;Claude Code = **只偵測不裝**（工單第六節:不代裝 git / Claude Code）。
- 徵同意 vs `--auto` 旗標:用可注入的輸入（stdin / 旗標）讓 y/n 決策可測。
- 缺必要依賴且偵測到套件管理器 → 組出「即將執行的安裝指令字串」（可斷言,不實跑）;缺必要且偵測不到套件管理器,**或缺的是 git/bash 本身** → 印官方下載連結並停（exit 非 0,不靜默 escalate）。
- 副作用（真正 `eval`/執行安裝指令）與純偵測/分類**分離**;純函式優先 TDD,副作用單獨包並 gate（徵同意/`--auto`）。
- 全純 bash 3.2、`bash -n` 過、靜態檢查零 LLM / 零網路（preflight 本身不下載;真安裝指令是套件管理器的網路行為,屬使用者徵同意後的副作用,不在 preflight 純函式內）。

**全工單成功標準（驗收）** = 工單第七節七條（冪等、依賴分層、模式 A 非侵入、模式 B 可攜、Windows、README、純 bash）。本回合只交 preflight 那條的純函式骨幹 + 副作用 gate。

---

## 2. 範圍 / 非範圍

**本計畫範圍（Slice 1）**:
- `lib/preflight.sh`:純函式庫——`dep_present`（依賴是否存在）、`dep_version`（抓版本字串）、`detect_pkg_manager`（套件管理器偵測,輸出單一 token）、`install_cmd_for`（給定 套件管理器 × 依賴 → 該跑的安裝指令字串,純對映,不執行）、`dep_tier`（依賴分層:required/optional/detect-only）、`should_install`（徵同意 vs `--auto` 的純決策,輸入可注入）、`preflight_report`（組分層報告文字）。
- `install.sh`:薄入口,parse `--auto`/`--help`,source `lib/preflight.sh`,跑 preflight 報告;**本片只接到「報告 + 依賴 gate 決策 + 缺必要無 pkg-mgr/缺 git 則印連結並停」**;真正執行安裝的副作用函式 `run_install`（單獨包、被 gate;本片以「印出將執行的指令 + 依注入決策決定跑不跑」形式落地,實跑指令的 mutation 由旗標/同意控制,不在 CI 真裝）。
- `tests/run.sh` 擴充:新 helper + 新 test 函式 + `$TESTS` 清單追加。

**明確排除（全工單級,記入計畫避免遺忘）**:
- ❌ 本回合**不碰** Slice 2（模式 A statusLine merge 進 `~/.claude/settings.json`）。
- ❌ 不碰 Slice 3（模式 B `--adopt`）、Slice 4（互動主選單 + `--update`）、Slice 5（install.ps1）、Slice 6（README）。
- ❌ 不代裝 git / Claude Code 本身（偵測到缺 → 引導下載連結）。
- ❌ 不靜默 escalate 系統權限（一律徵同意或 `--auto` 明示）。
- ❌ 不碰 v3-005/006 既有 hook / statusLine 腳本邏輯（只新增部署層）。
- ❌ 不在測試中**真正執行** `brew install` / `apt-get install` 等（會動系統 + 需網路 + 非冪等）。純函式只斷言「會組出哪條指令字串」與「依注入決策決定跑/不跑」。

**延後到後續 Slice**:模式 A merge（S2）、模式 B adopt（S3）、互動選單 + update（S4）、install.ps1（S5）、README（S6）。

---

## 3. 待老師批板:無 jq 時的 JSON merge fallback 策略（工單第八節第 3 項）

> 此項屬模式 A（Slice 2）與模式 B（Slice 3）的 settings.json merge,**非 Slice 1**。但工單要本回合計畫書先提案、老師批板,所以在此定案,Slice 2 動工才有依據。

**硬依賴 jq 的點**:模式 A 要把單一頂層 `statusLine` 鍵注入/更新進 `~/.claude/settings.json`,**保留其餘既有鍵**（如 `effortLevel`/`theme`/`model`）。模式 B 要把三個 hook 條目 merge 進目標 repo 的 `.claude/settings.json` 的 `hooks` 結構。前者是「設/換單一頂層鍵」,後者是「合併巢狀 hooks 陣列」。

**候選 (a) — 窄目標結構化 fallback（awk/sed,不引 jq）**
只處理「注入/更新單一頂層 `statusLine` 鍵」:
- 既有 settings 無 `statusLine` 鍵 → 在最外層 `{` 後插入一段 `"statusLine": {...},`。
- 既有有 `statusLine` 鍵 → 找到該鍵的物件值區段、整段替換。
風險評估:
- JSON 格式自由度高（縮排、單行 vs 多行、trailing comma 容忍度、巢狀物件值內也有 `}`）。窄目標 awk 要正確「找到 `statusLine` 物件值的結束 `}`」需配對括號計數,**對任意既有 JSON 形狀難安全**（使用者 settings 可能是壓成一行、可能 statusLine 值內含巢狀物件）。
- 寫壞 user-level `~/.claude/settings.json` = 高代價（影響所有專案的 Claude Code 啟動）。即使有備份,自動寫入一個解析不出的 JSON 仍是糟糕的失敗模式。
- 模式 B 的「合併巢狀 hooks 陣列」比模式 A 更難安全,(a) 幾乎不可行。

**候選 (b) — 偵測無 jq → 印待手動貼上的片段 + 明確指示,不自動寫檔（降級）**
- preflight 已把 jq 列可選依賴並徵同意安裝。若使用者**選擇不裝 jq** 且要跑模式 A/B 的 merge：
  - **不自動改 user-level / 目標 settings.json**。
  - 印出:① 應插入的精確 `statusLine`（或三 hook）JSON 片段（路徑已算好）;② 該貼進哪個檔的哪個位置;③ 一鍵還原指示。
  - exit 後由使用者手動貼上（或回頭裝 jq 再重跑,冪等保證安全）。

**我的推薦:候選 (b)（降級為印片段 + 指示）`(待老師批板)`**

理由:
1. **失敗代價不對稱**:jq present 是已查證事實（主路徑覆蓋實務絕大多數情況）。fallback 只在「使用者主動拒裝 jq + 仍要 merge」的罕見交集觸發。為這個罕見交集寫一個「對任意 JSON 形狀都安全的 awk merge」風險遠大於收益——寫壞 user-level settings 影響全域。
2. **冪等與非侵入更穩**:(b) 的「不自動寫檔、印片段」天然冪等（不寫就不可能重複注入）、零侵入（不動使用者檔）、可一鍵核對。完全符合工單設計原則 1（冪等）、3（非侵入 + 可一鍵回滾）。
3. **preflight 已給逃生道**:既然 preflight 會徵同意裝 jq,「無 jq」幾乎只在使用者明示拒裝時發生,此時「請你自己貼或回頭裝 jq」是合理且誠實的契約,不是偷懶。
4. **複雜度與可測性**:(b) 的純函式（組片段字串）易 TDD;(a) 的括號配對 merge 難寫難測、mutation 表面大,違反「最小實作」。

> 若老師批 (a)：我會把 (a) **嚴格限縮**為「只在既有 settings **無** `statusLine` 鍵時用 awk 在最外層 `{` 後插入」（最安全子集）,「已有舊 statusLine 要替換」與「模式 B 巢狀 hooks merge」仍走 (b) 印片段。即 (a) 與 (b) 混合、各取最安全路徑。等老師裁示。

---

## 4. 切片總表（垂直切,逐片 red-green + 驗收;冪等貫穿）

| # | 切片 | 本片冪等怎麼驗 | 端到端驗收 |
|---|---|---|---|
| 0 | 備份到私有 GitHub | （n/a,Ops） | **已完成**:遠端 47 commit |
| **1** | **preflight / doctor**（本回合） | preflight 純偵測**無副作用**→ 連跑多次報告一致、不改任何檔（fixture 鎖:跑前後 `git status` 不變；偵測函式不寫檔） | git 缺/present、jq 缺/present、`--auto`/互動各情境下分類與「該跑哪條安裝指令」正確；副作用安裝單獨包並 gate |
| 2 | 模式 A：merge statusLine | 重跑不重複注入（已有相同 statusLine → no-op；先備份）。fixture:乾淨/有他鍵/有舊 statusLine/壞 JSON 四種,各跑兩次斷言第二次無變化 | 保留既有鍵、路徑指向本機 clone、先備份、重跑不重複 |
| 3 | 模式 B：`--adopt <repo>` | 重跑不重複條目（已注入 → no-op）。fixture target repo 跑兩次,斷言 hooks 條目數不增 | 三 hook 注入、`$(git rev-parse)` 形式保留、冪等 |
| 4 | 互動主選單 + `--update` | `--update` = pull + 冪等重套（重跑安全） | 無旗標問 A/B/兩者；旗標非互動；update pull+重套 |
| 5 | install.ps1 Windows 入口 | （薄殼,轉呼冪等的 install.sh） | Windows 實跑（需甲方）；`$(git rev-parse)` 展開風險實測 |
| 6 | README / bootstrap | （Docs） | 照文件能從零裝起 + 回滾可循 |

**冪等性主軸（貫穿）**:Slice 1 的冪等性最單純——preflight 純偵測**本就無副作用**,所以「重跑一致」是天然的;測試以「偵測函式不寫任何檔」+「報告兩次相同」鎖死。真正的「重跑不重複注入」fixture 鎖落在 S2/S3（寫檔切片）,本片先把「副作用與純函式分離」的結構立好,讓 S2/S3 的寫檔副作用有乾淨的 gate 點。

---

## 4b. Slice 4 設計補充（互動主選單 + `--update`;動工前定案,test 鎖）

### 4b.1 互動主選單

**觸發條件**:`install.sh` 跑到 preflight gate 之後,且**未**給任何模式旗標
(`--mode-a` / `--adopt` / `--preflight-only` / `--update`) 時進互動選單。**旗標優先**:
任一模式旗標出現 → 走既有非互動分派,**不進選單**;`--auto`(無人值守)也**不進選單**
(無人值守不應卡在等輸入)。

**選項**:(A) 機器層安裝 Mode A / (B) 採用進某專案 Mode B / (both) 兩者都做 /
(q/退出) 略過。

**純邏輯 / 副作用分離(可測核心)**:
- `menu_choice_to_modes <choice>` — **純函式**:把使用者輸入的選擇 token 正規化映射成
  「要跑哪些模式」的穩定 token(stdout):`a`/`A`→`a`、`b`/`B`→`b`、`both`/`ab`/`c`→`both`、
  `q`/`quit`/空/其他→`none`。return 0。這是選單的可測心臟——不碰任何檔、不讀 tty,
  測試直接餵 choice 斷言映射。
- `run_menu <settings_file> <gauge> <src_root>` — **副作用 orchestrator**:從 stdin 讀
  choice(`read -r choice`),經 `menu_choice_to_modes` 正規化;Mode B 需要時再從 stdin
  讀一行 target 路徑;依結果分派到 `apply_statusline`(Mode A)/`adopt_repo`(Mode B)/兩者/
  no-op。**輸入注入方式 = stdin**(沿用 Slice 2/3 把資料餵進 stdin 的手法):測試以
  `printf 'a\n' | run_menu ...` 餵選擇、`printf 'both\n%s\n' "$target" | ...` 餵
  選擇+target,斷言分派正確。Mode A target 用注入的 `SETTINGS_FILE` fixture(**不碰真實
  `~/.claude/`**);Mode B target 用 mktemp git repo(**不碰真實 repo**)。

> 輸入注入決策:**純 stdin**(而非 `/dev/tty`)。理由:選單心臟是純 `menu_choice_to_modes`;
> `run_menu` 的讀取走 `menu_read_line`(`read -r line` from stdin)。真實互動時 stdin 即終端機,
> 測試以 pipe 餵 stdin。**刻意不用 `/dev/tty`**:在有控制終端的測試環境(本 harness 即是)下
> `/dev/tty` 可讀,會繞過 piped stdin 讓選單無法注入測試 — 故 menu 讀 stdin。
> (對比:Slice 2 的 `should_install` 同意走 `/dev/tty` 是因該決策的純心臟 `should_install`
> 已可注入測試,tty 只是 install.sh wiring 層;menu 的注入點即在 `run_menu` 本身,故用 stdin。)

### 4b.2 `--update`:pull 與重套分離

**scope 決定**:
- `--update` = 先更新本 repo,再**冪等重套 Mode A**(`apply_statusline`,已是最新則 no-op)。
- **pull 與重套分離**:pull 包成 `update_pull <repo_root>` 單一函式(唯一網路副作用),
  預設執行 `git -C <root> pull --ff-only`(只快轉,避免在本機改動上產生 merge commit /
  衝突——更安全的形式)。重套邏輯獨立呼叫冪等的 `apply_statusline`。
- **Mode B update scope**:**不追蹤** adopt 過的 target repo 清單(無註冊表;追蹤需新增持久化
  狀態 + 跨機器同步問題,複雜度與收益不成比例,傾向不做)。`--update` 對 Mode B 只**印提示**:
  「各 target repo 請自行 `git -C <repo> pull` 後重跑 `install.sh --adopt <repo>`(冪等)」。

**可測性(誠實標記)**:
- `update_pull` 真正 `git pull` 是網路/外部副作用,**測試不可真 pull**。落地方式:`do_update`
  orchestrator 呼叫 `update_pull`,測試可透過**覆寫 `update_pull` 函式**(在 source install
  的邏輯前先定義同名函式 stub,或以環境變數 `UPDATE_PULL_CMD` 注入無害指令)讓 pull 被 stub。
  本片採**環境變數注入**:`update_pull` 內若 `UPDATE_PULL_CMD` 有值則 `eval` 它(測試餵
  `printf SENTINEL` 之類無害指令)取代真實 `git pull`;未設則跑真實 `git -C <root> pull --ff-only`。
  這讓「pull 被呼叫到」可斷言、且**測試不觸網路**。
- **重套冪等**可在 `SETTINGS_FILE` fixture 下完整自動測(重跑 `apply_statusline` no-op)。
- **真實 `git pull` 那一行**(未注入 stub 時的 `git -C <root> pull --ff-only`)以 `bash -n`
  靜態通過 + 手動煙霧驗證(在本 repo clone 跑一次)涵蓋,**不納入自動 test**(網路副作用)。
  誠實標明:自動 test 鎖的是「update 會呼叫 pull(stub 可見) + 之後冪等重套 Mode A + 對
  Mode B 印提示」;真網路 pull 不在自動 test 內。

---

## 5. Slice 1 詳細規格（preflight / doctor）

### 5.1 依賴分層（tier）

| 依賴 | tier | 缺了怎麼辦 |
|---|---|---|
| `git` | **required** | 缺 git = 雞生蛋（部署器靠 git clone/pull）。**不代裝**,印官方連結 https://git-scm.com/downloads 並停（exit 非 0）。 |
| `bash` | **required**（已在跑 = 必存在；Windows 經 Git Bash 提供） | 正在執行 install.sh 代表 bash 存在;主要意義在 Windows 薄殼偵測（S5）。本片把 bash 列 required 但「正在跑 → present」。 |
| `jq` | **optional** | 缺 → 問一下徵同意裝（偵測到 pkg-mgr 時組指令）;**不裝也照跑**（hook/merge 有 awk fallback / 降級印片段）。 |
| Claude Code (`claude`) | **detect-only** | **只偵測不裝**（前提工具,工單第六節）。缺 → 報告標 missing + 印官方連結,但**不擋、不徵同意裝**。 |

> tier 用純函式 `dep_tier <name>` 回字串（`required`/`optional`/`detect-only`),不用 `declare -A`（bash 3.2 禁）——用 `case` 對映。

### 5.2 套件管理器偵測 `detect_pkg_manager`

純函式,輸出**單一 token**（stdout）+ return code。偵測序（present 即回,不再往下）:
- `brew`（macOS / Linuxbrew）→ `brew`
- `apt-get`（Debian/Ubuntu）→ `apt`
- `dnf`（Fedora/RHEL 新）→ `dnf`
- `yum`（RHEL 舊）→ `yum`
- `pacman`（Arch）→ `pacman`
- `zypper`（openSUSE）→ `zypper`
- `winget`（Windows,Git Bash 下可能可見）→ `winget`
- 都沒有 → stdout 空,return 1（→ 觸發「印連結並停」）。

偵測手段:`command -v <mgr> >/dev/null 2>&1`（沿用既有慣例,不用 `which`）。**可測性**:測試可注入一個只含特定 pkg-mgr stub 的 `PATH`（沿用 S5-4 的 `mktemp -d` + symlink 手法）斷言偵測結果,不依賴 CI 機器實際裝了哪個。

### 5.3 「該對某缺失依賴跑哪條安裝指令」純對映 `install_cmd_for`

`install_cmd_for <pkg_manager> <dep>` → stdout 印**將執行的指令字串**,return 0;不認識的組合 → stdout 空,return 1。對映（本片只需 `jq`,但對映表設計成可擴充）:

| pkg_manager | jq 安裝指令 |
|---|---|
| `brew` | `brew install jq` |
| `apt` | `sudo apt-get install -y jq` |
| `dnf` | `sudo dnf install -y jq` |
| `yum` | `sudo yum install -y jq` |
| `pacman` | `sudo pacman -S --noconfirm jq` |
| `zypper` | `sudo zypper install -y jq` |
| `winget` | `winget install jqlang.jq` |

> **純對映,不執行**——這是 TDD 的核心可測點:不裝任何東西就能斷言「brew × jq → `brew install jq`」。實際執行留給被 gate 的副作用函式 `run_install`，本片以 `eval` 包並由注入決策控制是否真跑（CI 不真跑）。`sudo` 出現在指令字串中 = 明示權限升級（工單原則:不靜默 escalate;指令字串會印給使用者看、徵同意後才跑）。

### 5.4 徵同意 vs `--auto` 純決策 `should_install`

`should_install <auto_flag> <answer>` → return 0（裝）/ 1（不裝）。純函式,輸入可注入:
- `auto_flag = 1`（`--auto`）→ 一律 return 0（無人值守,跳過確認）。
- `auto_flag = 0` → 看 `answer`（互動 y/n 的回覆,測試直接注入 `y`/`n`/空）:`y`/`Y`/`yes` → return 0;其餘（含空 = 直接 Enter）→ return 1（預設不裝,保守）。

> 互動讀取在 install.sh 用 `read -r answer </dev/tty`（或 stdin）取得後**傳進** `should_install`,讓決策邏輯純函式化、可注入測試。`--auto` 由 arg parse 設 `AUTO=1`。

### 5.5 缺必要依賴 / 缺 pkg-mgr 的「印連結並停」

- 缺 `git`（required 且不可代裝）→ 印 `git` 官方下載連結 + 訊息,return/exit 非 0（不嘗試任何安裝）。
- 缺**任一 required**（非 git,理論上 bash 也屬此但正在跑必存在）且 `detect_pkg_manager` return 1（偵測不到套件管理器）→ 印該依賴官方連結 + 「偵測不到套件管理器,請手動安裝」並停。
- 缺 required 且**有** pkg-mgr → 組指令、徵同意（或 `--auto`）→ 副作用 `run_install`。
- 缺 `jq`（optional）→ 同上徵同意,但**不裝也照跑**（不 exit 非 0）。
- 缺 Claude Code（detect-only）→ 報告 missing + 印連結,**不擋不裝**。

### 5.6 分層報告 `preflight_report`

組多行文字（stdout）:逐依賴印 `present`/`missing` + tier + 版本（present 時）。純函式（吃「偵測結果」為輸入或直接呼叫偵測函式;為可測,設計成可注入偵測結果或在 fixture PATH 下跑）。本片報告**只讀不寫**,連跑兩次輸出相同 = 冪等鎖的一部分。

### 5.7 副作用分離（關鍵紀律）

- **純函式**（`lib/preflight.sh`）:`dep_present` / `dep_version` / `detect_pkg_manager` / `install_cmd_for` / `dep_tier` / `should_install` / `preflight_report`——全部**不寫檔、不執行安裝、不需網路**,可在 fixture 下斷言。
- **副作用**:`run_install <cmd_string>`——唯一真正 `eval "$cmd_string"` 跑安裝的點,被 `should_install` 的決策 gate。本片測試**不真跑**安裝;測 `run_install` 的方式 = 注入一個無害的 `cmd_string`（如 `printf SENTINEL`）斷言「gate 開 → 執行了、gate 關 → 沒執行」,證明 gate 串對,而非真裝套件。

---

## 6. Slice 1 測試表（逐條 red→green,一次一行為;誠實標 red-driven vs witness）

> 全部沿用 `tests/run.sh` 純 bash runner。每條先寫 test、跑、**親眼確認 red**,才寫最小 green。witness（一寫即綠）做 mutation 查核（故意改壞→轉紅、還原→轉綠）。若某 test 一寫就綠且非預期 → 停下回報。

| # | test 名稱 | 新增/驗證行為 | red-driven / witness | 關鍵斷言 |
|---|---|---|---|---|
| P1 | `test_install_cmd_for_brew_jq` | `install_cmd_for brew jq` → `brew install jq`（函式誕生,127→0） | **red-driven** | stdout == `brew install jq`、rc 0 |
| P2 | `test_install_cmd_for_apt_jq` | apt 分支 | **red-driven**（逼出第二 pkg-mgr 分支） | stdout == `sudo apt-get install -y jq` |
| P3 | `test_install_cmd_for_all_managers_jq` | dnf/yum/pacman/zypper/winget 各對映 | witness（P1/P2 已立 case 骨架,補滿） | 各 == 預期字串 |
| P4 | `test_install_cmd_for_unknown_returns_1` | 不認識的 pkg-mgr → stdout 空 + rc 1 | witness（mutation:拔 default `return 1` → 紅） | rc 1、stdout 空 |
| P5 | `test_detect_pkg_manager_picks_brew_when_only_brew` | 注入只含 brew stub 的 PATH → `brew` | **red-driven**（函式誕生） | stdout == `brew`、rc 0 |
| P6 | `test_detect_pkg_manager_precedence_brew_over_apt` | PATH 同時有 brew+apt → 回 brew（偵測序鎖） | **red-driven**（逼出有序偵測,殺「隨便回一個」mutant） | stdout == `brew` |
| P7 | `test_detect_pkg_manager_apt_when_no_brew` | 只有 apt → `apt` | witness | stdout == `apt` |
| P8 | `test_detect_pkg_manager_none_returns_1` | 空 PATH（無任何 mgr）→ stdout 空 + rc 1 | witness（mutation:拔 `return 1` → 紅） | rc 1、stdout 空 |
| P9 | `test_dep_present_true_for_existing` | `dep_present` 對注入 stub 的工具 → rc 0 | **red-driven**（函式誕生） | rc 0 |
| P10 | `test_dep_present_false_for_missing` | 對不存在工具 → rc 1 | witness | rc 1 |
| P11 | `test_dep_tier_git_required_jq_optional_claude_detectonly` | 分層對映正確 | **red-driven**（函式誕生 + 三 tier 分支） | git→required / jq→optional / claude→detect-only |
| P12 | `test_dep_tier_unknown_defaults_optional` | 未知依賴 → 保守預設（optional,不誤判 required 擋人） | witness（mutation:改 default → 紅） | unknown→optional |
| P13 | `test_should_install_auto_always_yes` | `--auto`（auto=1）→ 一律裝（rc 0,不看 answer） | **red-driven**（函式誕生 + auto 短路） | auto=1,answer=n → rc 0 |
| P14 | `test_should_install_interactive_y_yes` | auto=0 + answer=y → rc 0 | **red-driven**（逼出 y 分支） | rc 0 |
| P15 | `test_should_install_interactive_n_or_empty_no` | auto=0 + answer=n / 空 → rc 1（保守預設不裝） | witness（mutation:把 default 改成裝 → 紅） | n→rc1、空→rc1 |
| P16 | `test_preflight_report_marks_present_and_missing_with_tier` | 報告對 present/missing 各標狀態 + tier（fixture PATH 控制 present/missing） | **red-driven**（報告組裝誕生） | 含 `git`/`required`、缺工具標 `missing` |
| P17 | `test_preflight_report_is_pure_no_writes` | **冪等鎖**:跑 preflight_report 兩次輸出相同 + 不寫任何檔（fixture dir 跑前後檔案集合不變） | witness（mutation:在報告函式裡偷寫檔 → 紅） | 兩次 stdout 相同、dir 無新檔 |
| P18 | `test_missing_git_prints_official_link_and_stops` | 缺 git（required 不可代裝）→ 印 git-scm 連結 + 非 0 退出,**不嘗試安裝** | **red-driven**（install.sh 缺-git 分支誕生） | 輸出含 `git-scm.com`、rc 非 0、無安裝指令被執行 |
| P19 | `test_missing_required_no_pkgmgr_prints_link_stops` | 缺 required + 偵測不到 pkg-mgr → 印連結 + 停 | witness/red-driven（視 P18 共用骨架而定;預設 red-driven 逼出 no-pkgmgr 分支） | 輸出含連結、rc 非 0 |
| P20 | `test_missing_optional_jq_does_not_block` | 缺 jq（optional）→ 報告 missing 但**不 exit 非 0**、流程續行 | **red-driven**（optional 不擋分支） | rc 0（preflight 不因缺 jq 失敗） |
| P21 | `test_claude_code_detect_only_never_installs` | 缺 claude（detect-only）→ 報告 missing + 連結,但**不徵同意、不組安裝指令** | witness（mutation:若誤把 claude 當 required/optional 去裝 → 紅） | 報告含 claude missing、無 claude 安裝指令被組出/執行 |
| P22 | `test_run_install_executes_only_when_gated_yes` | 副作用 `run_install`:gate=yes（should_install rc0）→ 執行注入的無害 cmd（留 SENTINEL）;gate=no → 不執行 | **red-driven**（副作用與 gate 串接誕生;**不真裝套件**,用 `printf SENTINEL` 當 cmd） | gate yes → SENTINEL 出現；gate no → 無 SENTINEL |
| P23 | `test_install_cmd_contains_sudo_for_apt_explicit_escalation` | apt/dnf/... 指令字串含 `sudo`（明示權限升級,非靜默）= 工單原則鎖 | witness | apt 指令含 `sudo`、brew 指令**不**含 sudo |

red-driven 推進新實作的:P1（install_cmd_for 地基）、P2（第二分支）、P5（detect_pkg_manager 地基）、P6（偵測序）、P9（dep_present 地基）、P11（dep_tier 三分支）、P13/P14（should_install auto + y）、P16（report 組裝）、P18（缺-git 停）、P19（no-pkgmgr 停）、P20（optional 不擋）、P22（run_install gate 串接）。其餘為 mutation-grade 區辨/邊界/原則 witness,誠實標記,未偽造 red;witness 全做 mutation 查核。

> **TDD 紀律自我約束**:嚴禁同時生成實作與其測試;每條先寫 test、跑、親眼確認 red,才寫最小 green。witness 若一寫即綠 = 正常（驗既有行為/邊界）,但要 mutation 查核佐證它真在驗東西。若 red-driven test 一寫就綠且非預期 → 停下回報。

---

## 7. 檔案清單與職責（Slice 1）

| 檔案 | 職責 | 本回合動作 |
|---|---|---|
| `lib/preflight.sh` | preflight 純函式庫（偵測/版本/pkg-mgr/指令對映/tier/同意決策/報告）+ 副作用 `run_install`（gate 後唯一執行點）。bash 3.2。 | **新增** |
| `install.sh` | 入口:parse `--auto`/`--help`、source preflight、跑報告、依 tier + pkg-mgr + 同意決策決定「裝 / 印連結停 / 續行」。本片只到 preflight gate,不碰模式 A/B。 | **新增**（骨架,後續 Slice 擴充模式 A/B/選單/update） |
| `tests/run.sh` | 擴充:preflight fixture helper（PATH stub 注入）+ P1–P23 test 函式 + `$TESTS` 清單追加。 | **修改** |

> `lib/` 放 repo 根（與既有 `hooks/lib/` 區隔——hooks 專屬 hooks lib;部署器 lib 放根 `lib/`,因 install.sh 在根）。或放 `install-lib/`,動工時定（傾向 `lib/preflight.sh`,寫死於本表）。

---

## 8. Commit 結構（Slice 1,過老師驗收後執行,本回合不 commit）

逐 test red→green 推進,tiny commits,大致:
1. `test: red — install_cmd_for brew jq mapping`（runner helper + P1,確認 red）
2. `feat: install_cmd_for pure mapping pkg-manager x dep (green P1/P2)`
3. 逐條:detect_pkg_manager / dep_present / dep_tier / should_install / preflight_report / 缺-git 停 / optional 不擋 / run_install gate …各自 red→green
4. `chore: install.sh entry wiring preflight (arg parse + gate)`
最後整片送老師驗收（測試表全綠 + `bash -n` 過 + 靜態檢查零 LLM/零網路）。

---

## 9. 待老師批板事項（本回合）

1. **（第 3 節）無 jq 時 JSON merge fallback 策略**:推薦**候選 (b)**（偵測無 jq → 印待手動貼上片段 + 指示,不自動寫檔）。理由見第 3 節（失敗代價不對稱、冪等非侵入、preflight 已給裝 jq 逃生道、可測性）。若老師批 (a) 則限縮為「僅無 statusLine 鍵時 awk 插入」最安全子集 + 其餘走 (b) 混合。`(待老師批板)`
2. **（第 7 節）preflight lib 落點**:`lib/preflight.sh`（repo 根 `lib/`）。若老師偏好 `install-lib/` 或併入 `hooks/lib/`,請示下。動工先以 `lib/preflight.sh` 進行。
