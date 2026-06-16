# v3-005 計畫書 — Plan-Gate Hook + File-Backed Handoff

**Status**: Draft
**工單**: `tickets/v3-005.md`
**作者**: 工程師 (engineer-tdd)
**日期**: 2026-06-16
**版本**: v2(吸收老師批改）

---

## v2 變更摘要（吸收老師必修 1/2 + 拍板）

> 本節記錄 v1 Draft → v2 的變更,動工前提。

**必修 1 — 絕對路徑是常態,重塑路徑處理（v1 最大漏洞）**
v1 的「絕對路徑→放行」會讓 gate 永不觸發:Edit/Write 的 `file_path` schema 保證是絕對路徑,真實 payload 全絕對 = 全放行。v2 改為**相對化**邏輯:
  1. 取出 `file_path`(絕對)。
  2. 求 repo root:優先用 stdin 的 `.cwd` → 退而用 `git rev-parse --show-toplevel`;canonical 化(`cd "$root" && pwd -P`)解 symlink。
  3. 把 `file_path` 相對化到 repo root。**落在 repo 外 → 放行(exit 0)**;落在 repo 內 → 用「相對路徑」做 workflow-surface 比對與 PlanStatusGuard。
  4. fixture stdin **一律用絕對路徑**(`"$dir/signals/x.py"`),對齊真實 payload。
  「repo 外放行」精確定義 = 絕對路徑且不在 repo root 之下,**不是**「只要絕對就放行」。
  → 重寫 Q5/Q6 的 stdin 範例、fixture 搭法、test #9;新增「路徑相對化」為 guard 的核心步驟。

**必修 2 — Q3 stderr 措辭拿掉「worker 自己改 Status 為 Approved」**
v1 措辭叫模型自行把 Status 改 Approved = 自我核准、繞過 gate。v3 三角分工下核准是老師職權。v2 解除條件改為:
  - (a) **停止編輯實作檔**,回報老師「此 active plan 待核准」;**或**
  - (b) 轉去編輯 plan 本身(`plans/` 是 workflow surface,永遠放行),把計畫推到可被核准的狀態。
  訊息明確寫「Do NOT edit the Status field yourself; approval is the orchestrator's step.」保留「自動品質閘、非使用者拒絕」「不要默默呆住」的精神。

**拍板（老師已定，見「決議」區）**
- Q4 worktree 一致性 **納入 Slice 1**;write/read 兩側都 `pwd -P`;test #11 要**兩個 case**(真匹配走 symlink / 真不匹配)。
- 測試框架 = **純 bash test runner**(零依賴)。
- 未知 plan 狀態 = **allow-list 語意:只有 `Approved` 放行**,其餘(Draft/Annotating/typo/未知)一律未核准。stderr 印 current status。fail-soft 只適用「解析失敗/檔不存在不拋例外」,不放寬 gate 判斷。

---

## 決議（老師已拍板，動工依此）

| 議題 | 決議 |
|---|---|
| Q3 stderr 措辭 | 拿掉自我核准;解除條件 = 回報老師求核准 **或** 改去 plan/workflow surface。明寫「Do NOT edit the Status field yourself」。 |
| Q4 worktree 一致性 | 納入 Slice 1。write/read 兩側 `pwd -P`。test #11 兩 case:① symlink 真匹配仍放行路徑 ② 第二行 root 指別處 → 降級無 plan。 |
| 測試框架 | 純 bash test runner(`tests/run.sh`),零依賴。 |
| 未知 plan 狀態 | allow-list:只有 `Approved` 放行,其餘一律未核准。stderr 印 current status。 |
| 路徑處理（必修 1） | file_path 絕對 → 求 repo root → 相對化;repo 外放行,repo 內用相對路徑比對。 |

---

**本回合交付**: v2 計畫書 + **僅 Slice 1 第一個 red→green 增量**(第一個 red test 用絕對路徑 stdin、親眼確認 red、最小 green)。停在第一個 green,不做 test #2~#12。

---

## 0. 已查證的環境事實（影響規格,非臆測）

這些事實在動工前已親手驗證,直接約束實作選型:

| 事實 | 來源 | 對規格的影響 |
|---|---|---|
| 本機 `/bin/bash` 是 **GNU bash 3.2.57**(macOS 預設) | `bash --version` | **禁用** associative array (`declare -A`)、`${var^^}` 大小寫轉換、`mapfile`/`readarray`。函式庫只能用 bash 3.2 語法。 |
| `jq` 1.7.1 **存在** | `jq --version` | jq 為主路徑;但工單要求 awk fallback,fallback 路徑也要實測(用 `PATH` 屏蔽 jq 模擬缺席)。 |
| `bats` **未安裝** | `command -v bats` | 測試框架不假設 bats。Slice 1 用**純 bash test runner**(自寫 `tests/run.sh`,每個 case 一個函式,印 PASS/FAIL + 退出碼)。若老師要求 bats,改用 bats 但需先裝;我傾向純 bash 以零依賴。**(需老師拍板,見回報)** |
| InvestSys 實作不在 `src/`,而在 `signals/ detectors/ scanners/ notifiers/ analysis/` 等模組目錄;測試集中在 `tests/test_*.py` | `ls /Volumes/Data 4T/Projects/0-InvestSys/` | Q7 的 contract `allowed_paths` 不能寫 `src/`,要寫 InvestSys 真實模組目錄。工單第二節原文「放行 src/ 下實作」需理解為「放行該 repo 的實作目錄」。 |
| Claude Code hook PreToolUse stdin payload 欄位:`session_id` / `transcript_path` / `cwd` / `hook_event_name` / `tool_name` / `tool_input`(對 Edit/Write 內含 `file_path`) | 官方 hooks 文件 https://docs.claude.com/en/docs/claude-code/hooks ;並以 repo-harness `hook-input.sh` 實作交叉印證(`.tool_input.file_path`、`.tool_name`、`.cwd` 等 jq path 一致) | 確定 stdin 解析的 jq path 為 `.tool_input.file_path`,fallback `.file_path`(工單 D2.1 已指定此序)。 |
| repo-harness 的 active-plan marker 路徑就是 `.ai/harness/active-plan`,policy 在 `.ai/harness/policy.json` | grep `/tmp/repo-harness/.ai/hooks/lib/workflow-state.sh` | 與工單 D1 一致,沿用此路徑。 |
| Claude Code 退出碼語意:hook `exit 0` 放行;`exit 2` = blocking,**stderr 回灌給模型**;其他非零(含 `exit 1`)= non-blocking error,stderr 只給使用者看、**動作照常執行** | 官方 hooks 文件「Hook output / Exit codes」段 | 釘死工單一票否決條款:擋一律 `exit 2`,絕不 `exit 1`。 |

> repo-harness 僅作機制交叉印證,**未 copy-paste 任何碼**;本計畫所有實作均依工單規格重寫。

---

## 第六節 8 題逐題回答

### Q1. 目標與成功標準

**完工長相**:在一個 repo 內掛上專案級 `.claude/settings.json` 後,當 agent(或工程師 subagent)嘗試對「實作檔」做 `Edit`/`Write` 時,若當前沒有「已核准(`Approved`)的 active plan」,在 `enforce` 模式下該次 Edit 被 `exit 2` 擋下,stderr 出現明示「自動品質閘」的訊息;`advice` 模式下只 stdout 提醒不擋;`off` 完全靜默。改 plan/docs 等 workflow surface 在任何狀態都放行。同時 session 結束自動把 git-derived 交接寫 `resume.md`,下次開場自動注入。

**驗收怎麼證明每道 guard 真擋/真放行**(本片只涵蓋 PlanStatusGuard):
用 fixture repo 跑**決策表**,每格一個獨立 test case,斷言「退出碼 + 輸出去處(stderr/stdout/靜默)」:

- 維度:`plan 狀態 {無 active plan, Draft, Annotating, Approved}` × `編輯目標 {改 signals/x.py(實作), 改 plans/foo.md(workflow surface)}` × `gate 模式 {off, advice, enforce}` = 4×2×3 = 24 格。
- 不變式斷言(整片的「一票否決」核心):
  - `enforce` + 未核准({無, Draft, Annotating}) + 改實作 → **exit 2 且訊息在 stderr、stdout 不含該訊息**。
  - `advice` + 同情境 → **exit 0 且提醒在 stdout、stderr 空**。
  - `off`(任何情境)→ **exit 0 且 stdout/stderr 皆空**(靜默)。
  - `Approved`(任何模式)→ **exit 0 靜默放行**。
  - 改 `plans/`(任何狀態任何模式)→ **exit 0 靜默放行**(workflow surface)。
- 全 24 格綠 = Slice 1 驗收通過。

成功標準另含工單第七節「無 LLM 呼叫、無網路、無 `exit 1` 當擋」——以 grep 靜態檢查 hook 原始碼佐證(無 `curl`/`http`/`anthropic`/`exit 1`)。

### Q2. 範圍 / 非範圍

**本計畫範圍(Slice 1)**:
- `hooks/lib/workflow-state.sh` 的子集:`get_active_plan` / `get_plan_status` / `set_active_plan` / `clear_active_plan`。
- `hooks/pre-edit-guard.sh`:stdin 解析 + workflow-surface 放行 + 絕對路徑放行 + gate mode 讀取 + **僅 PlanStatusGuard 一道**。
- `.claude/settings.json` 範本只掛 `PreToolUse: Edit|Write` 一條(指向 pre-edit-guard.sh)。
- 純 bash test runner + fixture repo。

**明確排除(全工單級,記入計畫避免遺忘)**:
- ❌ 不碰 user-level `~/.claude/`(只動 repo 內 `.claude/`)。
- ❌ 不引入 Waza / gstack / gbrain / CodeGraph / Bun。
- ❌ 不實作 `prompt-guard.sh` intent 分類器 / TypeScript decision table(41KB 那支一行不看)。
- ❌ 不做 WorktreeGuard 強制隔離、不做 plan transition 全狀態機。
- ❌ 不做 Codex 相容層、不做 security-sentinel。
- ❌ 不 copy-paste repo-harness 的碼。

**延後到後續 Slice(非本片)**:ContractScopeGuard(S2)、write-handoff + stop(S3)、session-start 注入(S4)、policy.json + INSTALL + 真實落地(S5)、加分項(TDD 提醒、PlanCompletenessGate)。本片**不碰** `contract_allows_path` / `policy_get`,gate mode 只讀 env(`V3_EDIT_PLAN_GATE`)+ 硬碼預設 `advice`;policy.json 讀取留 S5。

### Q3.（最關鍵）`exit 2` 已知行為風險 + stderr 措辭草案

**問題**:Claude Code PreToolUse `exit 2` 把 stderr 回灌給模型,但實務上(issue #24327)模型常把它**誤判為「使用者拒絕了這次操作」而停手等指示**,而非「讀懂這是品質閘 → 修正前置條件 → 重試」。repo-harness 未處理此措辭。

**緩解策略**:stderr 訊息必須做到三件事——(a) 明示「這是自動化品質閘,**不是**使用者拒絕」;(b) 給出**確定性的解除條件**,但**不含自我核准**(核准是老師職權);(c) 用祈使句要求模型走 productive 下一步(回報求核准 / 改去 workflow surface),而非默默呆住等人。

**確切措辭(v2,吸收必修 2 — 已拿掉自我核准)**(`enforce` + 未核准 + 改實作,寫到 **stderr**):

```
[PlanStatusGuard] BLOCKED (automated quality gate, exit 2 — this is NOT a user rejection).

This repo's pre-edit gate requires an APPROVED plan before editing implementation files.
Reason: the active plan is not approved.
  - active plan: <plans/foo.md | (none)>
  - current status: <Draft | Annotating | (no marker) | ...>
  - blocked edit target: <signals/x.py>

This is a deterministic workflow guard, not a human saying no. Do NOT stop and silently wait.
Do NOT edit the Status field yourself; approval is the orchestrator's step. To make progress,
do ONE of these:
  1. Stop editing implementation files and report to the orchestrator that this active plan
     is awaiting approval. Then retry this edit only after it is approved.
  2. Or edit a workflow surface instead (plans/, tasks/, docs/, .ai/, .claude/, *.md) — those
     are always allowed — e.g. improve the plan itself so it can be approved.
  3. Or, if this gate is misfiring, the user can set V3_EDIT_PLAN_GATE=advice (warn-only) or =off.
```

設計要點:
- 開頭 `BLOCKED (automated quality gate ... NOT a user rejection)` 一句把 #24327 誤判堵住。
- 「Do NOT stop and silently wait」對抗停手行為;但 productive 下一步是「回報求核准 / 改計畫」**不是**自己蓋章。
- **明寫「Do NOT edit the Status field yourself; approval is the orchestrator's step.」**——封死自我核准路徑。
- 變數槽(`<...>`)由 guard 填入實際 active plan 路徑 / current status(**含未知狀態原值,方便 debug**)/ 目標檔。
- allow-list 語意:只有 `Approved` 不會走到這段;其餘狀態(含 typo/未知)都會,並把原值印在 `current status` 槽。

### Q4. marker 的 worktree 一致性

**風險**:`.ai/harness/active-plan` marker 是檔案,若 agent 的 cwd 跑到另一個 repo / 另一個 worktree,讀到的可能是別 repo 的 marker,造成跨 repo 誤判(A repo 的 Approved 放行了 B repo 的 edit)。

**機制**(工單 D1 已指方向):
- `set_active_plan(plan_file)` 寫 marker 時,marker 檔內容寫**兩行**:第一行 plan 相對路徑,第二行 `pwd -P` 的絕對 repo root(canonical,解 symlink)。
- `get_active_plan()` 讀 marker 時,比對 marker 第二行的 root 是否等於當前 `git rev-parse --show-toplevel` 的 `pwd -P`。不一致 → 視同「無 active plan」(return 1),不採用該 marker。
- 為什麼用 `pwd -P`:macOS `/var` → `/private/var` 的 symlink、worktree 的 linked path 都需 canonical 比對才不誤判(repo-harness 的 `hook_normalize_file_path` 也處理同一類 symlink 問題,佐證此坑真實存在)。

**本片測試覆蓋(老師拍板:納入 Slice 1，test #11 要兩 case)**:
- **case ① 真匹配（symlink）**:fixture 故意走 macOS `/var` → `/private/var` symlink(例如把 repo 建在 `$TMPDIR` 底下,`$TMPDIR` 常是 `/var/folders/...` symlink 指向 `/private/var/...`)。write 側 `pwd -P` 與 read 側 `pwd -P` 都 canonical,即使 cwd 字面是 symlink path,canonical 後**仍判為同 repo → 不降級、走正常 plan 判斷**。
- **case ② 真不匹配**:marker 第二行 root 故意寫別處(`/some/other/repo`),`get_active_plan` 應 return 1(降級為無 active plan)→ enforce 下走 exit 2。
- 只測一半(只測 ②)不算過——必須兩 case 都綠,才證明 canonical 比對「該匹配的匹配、該擋的擋」。

### Q5. jq 缺席 fallback

**硬依賴 jq 的點**:只有「解析 stdin JSON 取 `file_path`」。其餘(`get_plan_status` 從 plan 檔抓 `**Status**:`、marker 讀寫)都是純文字檔操作,用 awk/grep 即可,**不碰 jq**。

**fallback 設計**:
- 主路徑:`jq -r '.tool_input.file_path // .file_path // empty'`。
- jq 缺席 fallback:用 awk 對 stdin 做**窄目標**萃取——只找 `"file_path"\s*:\s*"..."` 這個 key,取第一個值,解 `\"` 與 `\\` 跳脫。**不做通用 JSON parser**(那是無底洞),只認 Claude Code 對 Edit/Write 固定吐的扁平 `tool_input.file_path`。
- 失敗(兩路都取不到)→ `exit 0`(fail-soft,工單 D2.1:取不到 file_path 即放行)。

**怎麼測 fallback**:test runner 對「取 file_path」這個行為跑兩遍——一遍正常,一遍以 `PATH=/usr/bin env -i` 或在 wrapper 內把 `jq` 屏蔽(`jq(){ return 127; }` 或臨時 PATH 不含 jq),斷言 awk fallback 萃出的 file_path 與 jq 路徑**相同**。這保證「有沒有 jq,行為一致」。fallback 表測在本片屬於 PlanStatusGuard 的 stdin 解析子行為,可納入;完整 `policy_get` 的 jq/awk 表測留 S5。

### Q6. 測試策略 + 第一個 red test

**框架**:純 bash test runner(`tests/run.sh`),零外部依賴。每個 test case 是一個 shell 函式,內部:備妥 fixture repo → 設 env → 把預先準備好的 stdin JSON `pipe` 進 `pre-edit-guard.sh`(或直接呼叫 lib 函式)→ 捕捉 `exit code` / `stdout` / `stderr` 三者 → 斷言。輸出 `PASS/FAIL`,任一 FAIL 則 runner `exit 1`。

**fixture repo 怎麼搭**(Slice 1):
test 在 `mktemp -d` 建臨時 repo,`git init`,結構:
```
<tmp-repo>/
  .git/
  .ai/harness/active-plan        # marker,內容兩行:plan 相對路徑 + repo root 絕對路徑
  plans/foo.md                   # plan 檔,含 "**Status**: <狀態>"
  signals/x.py                   # 假實作檔(編輯目標)
  .claude/settings.json          # (掛 hook 用,直接呼叫 guard 測時可省)
```
不同情境的搭法:
- **無 active plan**:不建 `.ai/harness/active-plan`(或建但指向不存在的 plan)。
- **Draft / Annotating / Approved**:建 marker 指向 `plans/foo.md`,該檔 `**Status**:` 分別寫 `Draft` / `Annotating` / `Approved`。
- **改實作 vs 改 plan**:stdin JSON 的 `file_path` 分別給 `signals/x.py` 與 `plans/foo.md`。
- **三態 gate**:設 `V3_EDIT_PLAN_GATE=off|advice|enforce`(本片 mode 來源只有 env)。

**第一個 red test(one-behavior)**:

> **test 名稱**:`test_enforce_no_active_plan_edit_impl_blocks_exit2_stderr`
> **行為**:`enforce` 模式 + 完全無 active plan marker + 編輯實作檔 `signals/x.py` 時,guard 必須 `exit 2`,且 blocking 訊息寫在 **stderr**。
> **具體斷言**(三條同時成立才算過):
> 1. `exit_code == 2`
> 2. `stderr` 含子字串 `PlanStatusGuard` 且含 `NOT a user rejection`(證明措辭到位、走的是 stderr)
> 3. `stdout` **不**含上述 blocking 訊息(證明沒寫錯管道)
>
> **為何選它當第一個 red**:它一次釘死整片最高風險的「一票否決」——退出碼 2 + 訊息走 stderr。red 階段:此時 `pre-edit-guard.sh` 尚未實作 PlanStatusGuard(或只有骨架 `exit 0`),預期 `exit_code` 會是 0、stderr 空 → 三條斷言全敗 → 確認 red。green:寫剛好讓這條過的最小 PlanStatusGuard(無 active plan + enforce → 印措辭到 stderr + exit 2),**不順手實作 advice/off/Approved 分支**。

**後續 test 順序表**(逐條 red→green,一次一行為;每條都是獨立 fixture):

| # | 狀態 | test 名稱 | 新增行為(這條才驗證的) | 關鍵斷言 |
|---|---|---|---|---|
| 1 | [x] | `test_enforce_no_active_plan_edit_impl_blocks_exit2_stderr` | enforce+無plan+改實作 → 擋 | exit 2 / 訊息在 stderr / stdout 無 |
| 2 | [x] | `test_enforce_approved_edit_impl_passes_silent` | Approved 放行(引入 get_plan_status + Approved 分支) | exit 0 / stdout 空 / stderr 空 |
| 3 | [x] | `test_enforce_draft_edit_impl_blocks` | Draft 視為未核准 → 擋(此條 red 才逼出 get_plan_status) | exit 2 / stderr 有訊息 + 印 Draft |
| 4 | [x]※ | `test_enforce_annotating_edit_impl_blocks` | Annotating 視為未核准 → 擋 | exit 2 / stderr 印 Annotating |
| 5 | [x] | `test_enforce_no_plan_edit_plan_surface_passes` | 改 `plans/foo.md` → workflow surface 放行(即使未核准) | exit 0 / 靜默 |
| 6 | [x] | `test_advice_no_plan_edit_impl_warns_exit0` | advice 模式 → 不擋只提醒(提醒走 stdout) | exit 0 / stdout 有提醒 / stderr 空 |
| 7 | [x] | `test_off_no_plan_edit_impl_silent` | off 模式 → 完全靜默放行 | exit 0 / stdout 空 / stderr 空 |
| 8 | [x]※ | `test_missing_file_path_in_stdin_passes` | stdin 無 file_path → fail-soft 放行 | exit 0 |
| 9 | [x]※ | `test_abs_path_outside_repo_passes` | file_path 絕對且**落在 repo root 之外** → 放行(repo 外不管轄) | exit 0 / 靜默 |
| +5 | [x] | `test_repo_internal_new_file_in_new_dir_gated` | (綁定約束 #5)repo 內新檔在新目錄 → fallback 不漏判 repo 外 → 仍擋 | exit 2 / stderr 印 signals/new/y.py |
| 10 | [x]※ | `test_file_path_extracted_without_jq_matches_jq` | jq 缺席 awk fallback 取 file_path 與 jq 一致 | jq vs no-jq exit/stderr 全等 |
| 11a | [x]※ | `test_marker_root_worktree_consistency_symlink_match` | Q4 case①:symlink 真匹配仍走正常判斷 | 走 plan 路徑:stderr 印 plans/foo.md + Draft |
| 11b | [x]※ | `test_marker_root_worktree_consistency_root_mismatch_degrades` | Q4 case②:root 指別處 → 降級無 plan(Approved 也忽略) | get_active_plan return 1 → stderr 印 (none)/(no marker) |
| 12 | [x]※ | `test_workflow_surface_md_and_docs_pass` | `docs/ tasks/ .ai/ .claude/ *.md` 各放行(補齊 surface 清單) | exit 0 / 靜默 |

※ = witness/regression test(一寫即綠,驗證的是先前 green 已實作的既有行為或邊界,非由此條 red 驅動新實作)。誠實標記,未偽造 red。真正由 red 驅動新實作的:#1(地基)、#2+#3(get_plan_status + allow-list)、#5(surface bypass)、#6(advice)、#7(off)、+5(nearest-ancestor canonicalization 修漏)。

(完整 4×2×3=24 格決策表以參數化 helper 補滿;上表是逐行為推進的骨幹,每行為一個獨立 red→green→可選 refactor。)

**TDD 紀律自我約束**:嚴禁同時生成實作與其測試;每條先寫 test、跑、親眼確認 red,才寫最小 green。若某 test 一寫就綠 → 停下回報(代表沒驗證到新行為)。

### Q7. InvestSys 落地的 allowed_paths 範例 ✅ Slice 2 已實作並實測通過

> Slice 2 已實作 ContractScopeGuard + `contract_allows_path`。Q7 表已實測(clean bash subprocess):
> `signals/vix.py` / `tests/test_vix.py` / `config/foo.yaml` → ALLOW(全 OK);
> `deploy/secrets.env` / `portfolio.yaml` / `web/app.js` → BLOCK(全 OK)。6/6 命中預期。
> 已核實 InvestSys 結構:實作在模組目錄,非 `src/`。

InvestSys 真實頂層(節錄):`signals/ detectors/ scanners/ notifiers/ analysis/ utils/ tools/ scripts/ web/ tests/ config/ deploy/ docs/`。

提案 contract 片段(供 S2 驗證,放 `.ai/harness/contract.md` 之類):
```yaml
allowed_paths:
  - signals/        # 前綴比對(以 / 結尾):放行 signals/ 下全部實作
  - detectors/
  - scanners/
  - notifiers/
  - analysis/
  - utils/
  - tests/test_*.py # glob 比對(不以 / 結尾):放行測試檔
  - config/*.yaml
```
驗證預期(S2 表測):
- 放行:`signals/vix.py`(命中 `signals/` 前綴)、`tests/test_vix.py`(命中 `tests/test_*.py` glob)、`config/foo.yaml`(命中 glob)。
- 擋掉:`deploy/secrets.env`(`deploy/` 不在清單)、`portfolio.yaml`(repo 根、無目錄前綴、不命中任何項)、`web/app.js`(`web/` 不在清單)。

`contract_allows_path` 規則(工單 D1):項目以 `/` 結尾 → 前綴比對(`case "$rel" in "$item"*`);否則 → glob 比對(`case "$rel" in $item`)。任一命中 return 0,否則 return 1。**Slice 2 已實作。**

#### Slice 2 測試表(逐條 red-driven vs witness,已全綠)

| # | test 名稱 | 驗證行為 | red-driven / witness |
|---|---|---|---|
| S2-1 | `test_contract_allows_path_prefix_hit` | `signals/` 前綴命中 `signals/vix.py` | **red-driven**(函式誕生,127→0) |
| S2-2 | `test_contract_allows_path_prefix_miss` | `deploy/secrets.env` 不命中 → return 1 | witness |
| S2-3 | `test_contract_allows_path_glob_hit_tests` | `tests/test_*.py` glob 命中 | **red-driven**(揪出參數展開吃字元 bug) |
| S2-4 | `test_contract_allows_path_glob_hit_config` | `config/*.yaml` glob 命中 | witness |
| S2-5 | `test_contract_allows_path_no_yaml_block_returns_1` | 無 yaml 區塊 → return 1(no-op 基礎) | witness |
| S2-6 | `test_contract_allows_path_prefix_not_treated_as_glob` | `signals/` 深層 `signals/sub/deep.py` 命中(殺 prefix-as-glob mutant) | witness |
| S2-7 | `test_contract_allows_path_glob_not_treated_as_prefix` | `config/foo.yaml.bak` 不命中(glob 尾錨定,殺 glob-as-prefix mutant) | witness |
| S2-8 | `test_contractscope_enforce_out_of_scope_blocks_exit2_stderr` | enforce+Approved+範圍外 → exit 2 + `[ContractScopeGuard]` stderr | **red-driven**(guard 接進鏈) |
| S2-9 | `test_contractscope_enforce_in_scope_prefix_passes_silent` | 範圍內(prefix)放行靜默 | witness |
| S2-10 | `test_contractscope_enforce_in_scope_glob_passes_silent` | `tests/test_vix.py` 放行 | witness |
| S2-11 | `test_contractscope_enforce_in_scope_config_glob_passes_silent` | `config/foo.yaml` 放行 | witness |
| S2-12 | `test_contractscope_enforce_reporoot_file_blocks` | `portfolio.yaml`(repo 根)→ 擋 | witness |
| S2-13 | `test_contractscope_enforce_web_dir_blocks` | `web/app.js` → 擋 | witness |
| S2-14 | `test_contractscope_noop_approved_no_yaml_block_passes` | Approved 但無 yaml 區塊 → no-op 放行(opt-in 關) | witness |
| S2-15 | `test_contractscope_advice_out_of_scope_warns_exit0` | advice → exit 0 + stdout 提醒 | witness |
| S2-16 | `test_contractscope_off_out_of_scope_silent` | off → exit 0 靜默 | witness |
| S2-17 | `test_chain_order_draft_out_of_scope_blocked_by_planstatus_not_contract` | Draft+範圍外 → `[PlanStatusGuard]` 先擋,**非** ContractScope(鏈序證明) | witness |

red-driven 推進新實作的:S2-1(函式地基)、S2-3(glob 分支 + 修參數展開 bug)、S2-8(接進 guard 鏈)。其餘為 mutation-grade 區辨/邊界/決策表 witness,誠實標記,未偽造 red。

### Slice 3 — write-handoff (D3) + stop-orchestrator (D4 主體) ✅ 已實作並全綠

> D3 `hooks/lib/write-handoff.sh` 的 `write_handoff(reason)` + D4 `hooks/stop-orchestrator.sh` Stop hook + settings.json 掛 Stop。
> 零 LLM、零網路:交接內容全由 `git` + 檔案狀態算出。**不實作** PlanCompletenessGate(留最後一片)。

#### Slice 3 測試表(逐條 red-driven vs witness,已全綠)

| # | test 名稱 | 驗證行為 | red-driven / witness |
|---|---|---|---|
| S3-1 | `test_handoff_writes_active_plan_and_status` | resume.md 記 active plan 路徑 + 狀態 | **red-driven**(lib 誕生,127→0) |
| S3-2 | `test_handoff_changed_files_union_dedup_sorted` | changed = tracked-modified ∪ untracked,去重+排序 | **red-driven**(changed-files 區塊地基) |
| S3-3 | `test_handoff_changed_files_truncated_past_80` | >80 → 截斷至 80 + 總數標記 | **red-driven**(截斷邏輯) |
| S3-4 | `test_handoff_shortstat_line_from_git` | `git diff --shortstat HEAD` 逐字寫入 | **red-driven**(shortstat 行) |
| S3-5 | `test_handoff_records_time_and_reason` | UTC ISO8601 時間 + reason 存在 | witness(S3-1 已實作) |
| S3-6 | `test_handoff_non_git_repo_degrades` | 非 git → 只時間+reason、無 git 錯誤外漏、無 changed/diff 區塊 | **red-driven**(降級分支) |
| S3-7 | `test_handoff_changed_block_reproducible_lock` | changed 區塊逐行 == 獨立算出的 git union 集合(可複現鎖) | witness(反模型生成痕跡鎖) |
| S3-8 | `test_stop_hook_writes_resume_and_exits_0` | Stop hook 刷新 resume.md + `exit 0` | **red-driven**(hook 誕生,127→0) |
| S3-9 | `test_handoff_idempotent_overwrite` | 兩次呼叫覆寫(單一 header、最新 reason) | witness(`> "$out"` 覆寫) |

red-driven 推進新實作的:S3-1(lib 地基 + active plan)、S3-2(union/dedup/sort)、S3-3(截斷)、S3-4(shortstat)、S3-6(非-git 降級)、S3-8(stop hook 接 wiring)。S3-5/S3-7/S3-9 為 witness/可複現鎖,誠實標記,未偽造 red。

settings.json:`Stop` hook 已加掛(`timeout: 30`),`PreToolUse` 條目原封不動。**PlanCompletenessGate 未實作**(老師排除本片)。

### Slice 4 — session-start 注入 (D5) ✅ 已實作並全綠

> D5 `hooks/session-start-context.sh` SessionStart hook。讀 `.ai/harness/handoff/resume.md`(Slice 3 產出)+ `tasks/current.md`(若存在),純文字 stdout、`exit 0`。
> 零 LLM、零網路:內容只來自讀檔。**靈魂**:輸出明標 **recovery context only** + 當前輸入優先 disclaimer,框住任何注入的舊狀態。

#### Slice 4 測試表(逐條 red-driven vs witness,已全綠)

| # | test 名稱 | 驗證行為 | red-driven / witness |
|---|---|---|---|
| S4-1 | `test_session_start_resume_content_wrapped_in_disclaimer` | resume.md 內容出現在 stdout,且 disclaimer 在前框住 | **red-driven**(hook 誕生 127→0 + disclaimer 地基) |
| S4-2 | `test_session_start_includes_current_task_when_present` | `tasks/current.md` 存在 → 內容也被注入 | **red-driven**(current-task 分支) |
| S4-3 | `test_session_start_no_resume_degrades_gracefully` | resume.md 不存在 → exit 0、stderr 空 | witness(mutation-checked) |
| S4-4 | `test_session_start_no_files_at_all_exits_0` | 全無檔(連 .ai 樹都無)→ exit 0、stderr 空 | witness(mutation-checked) |
| S4-5 | `test_session_start_disclaimer_present_when_only_current_task` | 只有 current.md(無 resume)→ disclaimer 仍在前框住 | **red-driven**(disclaimer 提出 resume-only 分支) |
| S4-6 | `test_session_start_disclaimer_soul_substrings_locked` | 靈魂鎖:disclaimer 全部承重子串實際出現 | witness(mutation-checked) |
| S4-7 | `test_settings_wires_session_start_and_preserves_pretooluse_stop` | settings.json 掛 SessionStart 且 PreToolUse/Stop 不動 | **red-driven**(settings wiring) |

red-driven 推進新實作的:S4-1(hook 地基 + disclaimer)、S4-2(current.md 分支)、S4-5(disclaimer 提出 resume-only 分支,框住任何注入狀態)、S4-7(settings wiring)。S4-3/S4-4/S4-6 為 graceful-degradation / 靈魂鎖 witness,均經 mutation 查核(故意改壞 → 轉紅、還原 → 轉綠),非偽造 red。

settings.json:`SessionStart` hook 已加掛(`timeout: 30`),`PreToolUse` / `Stop` 條目原封不動。靜態檢查:hook 內無 `exit 1`/`exit 2`(唯一 exit 為 `exit 0`)、無 `curl`/`wget`/`anthropic`/`http`、無 bash 3.2 禁構式。

### Q8. 回滾(一鍵停用)

掛上 hook 後若行為異常,三層停用手段(由輕到重):
1. **降模式**:`export V3_EDIT_PLAN_GATE=off`(或 `advice`)——立即讓 PlanStatusGuard 不再擋,不動任何檔。最輕、最快。
2. **官方總開關**:`.claude/settings.json` 設 `"disableAllHooks": true`(官方 hooks 文件提供),一鍵停掉該 repo 全部 hook。
3. **拔區塊**:刪除/註解 `.claude/settings.json` 裡 `hooks.PreToolUse` / `hooks.Stop` 的對應條目,或整檔還原(repo 內、進 git,`git checkout .claude/settings.json` 即復原)。

`INSTALL.md`(S5 交付)會把這三層寫成清楚步驟。因 hook 全掛**專案級** settings、未動 user-level,最壞情況刪掉 repo 內 `.claude/settings.json` 即完全脫鉤,不影響其他專案。

---

## Slice 1 規格(PlanStatusGuard 三態端到端)

### 檔案清單與職責

| 檔案 | 職責(本片範圍內) |
|---|---|
| `hooks/lib/workflow-state.sh` | 共用函式庫子集:marker 讀寫 + plan 狀態解析。本片只實作 `get_active_plan` / `get_plan_status` / `set_active_plan` / `clear_active_plan`。bash 3.2 相容。 |
| `hooks/pre-edit-guard.sh` | PreToolUse on Edit\|Write 的 guard 主體。本片:讀 stdin → 取 file_path(jq + awk fallback)→ 取不到則 exit 0 → workflow-surface / 絕對路徑放行 → 讀 gate mode(env `V3_EDIT_PLAN_GATE`,預設 advice)→ off 則 exit 0 → 跑 PlanStatusGuard → 依 mode 決定 exit 2(enforce)/ stdout 提醒+exit 0(advice)。 |
| `.claude/settings.json` | 範本:只掛 `PreToolUse` matcher `Edit\|Write` → 一條 command 指向 `pre-edit-guard.sh`,以 `git rev-parse --show-toplevel` 解 repo root、`timeout: 30`。本片只放這一條 hook。 |
| `tests/run.sh` | 純 bash test runner;建臨時 fixture repo、餵 stdin JSON、捕捉 exit/stdout/stderr、斷言、印 PASS/FAIL。 |
| `tests/fixtures/`(helper) | 建 fixture repo 的 helper 函式(`make_fixture_repo`、`set_marker`、`write_plan_status`、`make_stdin`)。 |

### 介面簽章與回傳語意(`workflow-state.sh`)

> bash 函式無真正回傳值;約定:**狀態**用 exit/return code(0=成功/真,非0=失敗/假),**資料**用 stdout 印出。

- **`get_active_plan()`**
  - 入:無參數(讀環境/marker)。
  - 行為:讀 `.ai/harness/active-plan` marker;若不存在 → return 1。若存在,讀第一行(plan 相對路徑)與第二行(寫入時的 repo root,canonical);把第二行與當前 repo root 都 `cd … && pwd -P` canonical 後比對,**不一致** → return 1(worktree 一致性,Q4,解 symlink);若 plan 檔不存在 → return 1。
  - 回傳:成功時 **stdout 印 plan 相對路徑**,return 0;否則 return 1、stdout 空。

- **`get_plan_status(plan_file)`**
  - 入:`$1` = plan 檔路徑(相對 repo root)。
  - 行為:awk 抓首個 `**Status**:` 欄位值(`awk '/\*\*Status\*\*:/ {sub(/^.*\*\*Status\*\*: */,""); print; exit}'`),去前後空白。
  - 回傳:找到 → **stdout 印狀態字串**(如 `Approved`),return 0;檔不存在或無 Status 欄 → return 1、stdout 空。

- **`set_active_plan(plan_file)`**
  - 入:`$1` = plan 相對路徑。
  - 行為:`mkdir -p .ai/harness`;寫 marker 兩行——第一行 plan 路徑,第二行 `pwd -P`(canonical repo root)。
  - 回傳:寫成功 return 0,否則 return 1。

- **`clear_active_plan()`**
  - 入:無。
  - 行為:刪除 `.ai/harness/active-plan` marker(存在才刪;不存在視為已清,不報錯)。
  - 回傳:return 0(冪等)。

> 「未核准」判定(allow-list 語意，老師拍板；供 pre-edit-guard 用,本片不單獨開函式,內聯於 guard):
> `get_active_plan` 失敗(無 active plan)**或** `get_plan_status` **≠ `Approved`** → 未核准 → 擋(依 mode)。
> **只有 `Approved` 放行**;其餘(`Draft`/`Annotating`/typo/未知/解析不到)一律未核准。stderr 印出 current status 原值方便 debug。
> fail-soft(解析失敗/檔不存在不拋例外)只影響「不 crash」,**不放寬** gate 判斷——解析不到狀態 = 未核准。

### pre-edit-guard.sh 收到的 stdin JSON 範例

依官方 hooks 文件,PreToolUse 對 `Edit` 工具的 stdin payload 形狀(欄位名已查證,非臆測):

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/bjchen/.claude/projects/.../<uuid>.jsonl",
  "cwd": "/Volumes/Data 4T/Projects/0-InvestSys",
  "hook_event_name": "PreToolUse",
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "/Volumes/Data 4T/Projects/0-InvestSys/signals/x.py",
    "old_string": "...",
    "new_string": "..."
  }
}
```

> **必修 1**:`tool_input.file_path` **一定是絕對路徑**(Edit/Write 工具 schema 證實 "must be absolute")。v1 寫相對 `signals/x.py` 是錯的。fixture stdin 一律用絕對路徑。

對 `Write` 工具,`tool_input` 為 `{ "file_path": "...", "content": "..." }`。
guard 取 file_path 的 jq path 序:`.tool_input.file_path` → `.file_path`(後者為防禦性 fallback)。取到的是**絕對路徑**,guard 接著做相對化(見下節「路徑相對化」)。
> 來源:官方 hooks 文件 PreToolUse input schema + Edit/Write 工具 schema(file_path must be absolute)。

### 路徑相對化（必修 1，guard 核心步驟）

guard 取到絕對 `file_path` 後:
1. **求 repo root**:優先 stdin `.cwd`;若無,`git rev-parse --show-toplevel`。canonical 化:`root=$(cd "$root" && pwd -P)`。
2. **canonical file_path 的所在**:取 `file_path` 的 dirname,`cd` 進去 `pwd -P` 後接回 basename(解 symlink,對齊 root 的 canonical)。
3. **相對化**:若 canonical file_path 以 `root/` 為前綴 → 去掉前綴得相對路徑,進入 workflow-surface 比對 + PlanStatusGuard。
4. **repo 外放行**:若 canonical file_path **不在** `root/` 之下 → `exit 0`(repo 外不管轄)。
   注意:「repo 外放行」= 絕對且不在 root 底下,**不是**「只要絕對就放行」。

### fixture repo 怎麼搭(細節)

test helper `make_fixture_repo` 流程:
1. `dir=$(mktemp -d)`;`git -C "$dir" init -q`(讓 `git rev-parse --show-toplevel` 可解;部分放行邏輯與 marker root 比對依賴 repo root)。
2. `mkdir -p "$dir/signals" "$dir/plans" "$dir/.ai/harness"`;`: > "$dir/signals/x.py"`。
3. 視情境寫 plan:`printf '# foo\n\n**Status**: %s\n' "$STATUS" > "$dir/plans/foo.md"`。
4. 視情境塞 marker:
   - 有 active plan:`printf '%s\n%s\n' "plans/foo.md" "$(cd "$dir" && pwd -P)" > "$dir/.ai/harness/active-plan"`。
   - 無 active plan:不建此檔。
   - root mismatch case(Q4):第二行故意寫 `/some/other/repo`。
5. 餵 stdin:`make_stdin "$dir/signals/x.py"`——**必修 1:用絕對路徑**(`"$dir/..."`),不准再用相對 `signals/x.py`。stdin JSON 的 `.cwd` 也填 `$(cd "$dir" && pwd -P)`,讓 guard 能從 stdin 求 repo root。test 以 `printf '%s' "$json" | (cd "$dir" && V3_EDIT_PLAN_GATE=$MODE bash "$REPO/hooks/pre-edit-guard.sh")` 執行,`2>stderr.txt 1>stdout.txt`,`echo $?` 捕退出碼。

斷言 helper:`assert_exit`、`assert_stderr_contains`、`assert_stdout_empty` 等,FAIL 累加,runner 結束依累加數 exit。

### `.claude/settings.json` 範本(本片只掛一條,規格層描述,不在本回合落檔)

`PreToolUse` → matcher 精確 `Edit|Write` → 一條 `type: command` hook,command 形如「以 `git rev-parse --show-toplevel` 解 repo root、export `HOOK_REPO_ROOT`、`bash $repo/hooks/pre-edit-guard.sh`」,`timeout: 30`。(實際 bash 字串過批改後才寫。)

---

## Commit 結構(Slice 1,過批改後執行,本回合不 commit)

逐 test red→green 推進,粒度乾淨;大致:
1. `test: red — enforce+no-plan+impl edit must exit 2 to stderr`(含 runner 骨架 + 第一條 test,確認 red)
2. `feat: PlanStatusGuard blocks unapproved impl edits with exit 2 (green #1)`
3. 逐條:Approved 放行 / Draft / Annotating / workflow-surface / advice / off / missing-file_path / absolute-path / jq-fallback / marker-root-mismatch …各自 red→green(每行為 1~2 個 commit)
4. `chore: .claude/settings.json template wiring PreToolUse Edit|Write`
最後整片送老師驗收(決策表全綠 + 靜態檢查無 `exit 1`/無 LLM 呼叫)。

---

## 待老師拍板事項（v1 提問 → v2 已全數拍板，記錄結論）

1. **(Q3 措辭)** ✅ 已拍板:拿掉自我核准。解除條件 = 回報老師求核准 **或** 改去 plan/workflow surface。明寫「Do NOT edit the Status field yourself; approval is the orchestrator's step.」(見 Q3 v2 措辭)
2. **(Q4 範圍)** ✅ 已拍板:**納入 Slice 1**。write/read 兩側 `pwd -P`;test #11 兩 case(symlink 真匹配 / root 不匹配)。
3. **(測試框架)** ✅ 已拍板:**純 bash test runner**,零依賴。
4. **(未知 plan 狀態)** ✅ 已拍板:**allow-list,只有 `Approved` 放行**;其餘一律未核准;stderr 印 current status;fail-soft 不放寬 gate。
5. **(必修 1 路徑)** ✅ 已拍板:絕對 file_path → 求 repo root → 相對化;repo 外放行(非「只要絕對就放行」)。

本回合無待拍板項。
