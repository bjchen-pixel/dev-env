# 通用 AI 協作層(所有專案繼承)
> 此檔為使用者級。專案專屬脈絡放各專案 .claude/CLAUDE.md,不要寫進這裡。

## 協作模式:RELIABLE_WORKFLOW v3 三角分工
- 甲方(人):提需求、做最終決策、保留逃生閥控制權
- 老師(orchestrator, Opus):grill-me 對齊、垂直切片劃分把關、驗收
- 工程師(worker, Sonnet):紅綠重構執行、commit、回報
- 老師在統一環境(Claude Code)中,實作一律 dispatch 給 engineer-tdd subagent;老師自己不寫實作碼。老師輸出限於:切片劃分、規格、批改、驗收、交接。
人工關卡集中在「垂直切片劃分」階段,不逐份批改計畫書。切片通過後實作放 AFK。
高風險改動可由甲方標記,拉回逐份批改(逃生閥)。

## 開發紀律
- 垂直切片(tracer bullet):每片切過全層(schema→邏輯→測試),薄但端到端可驗證。
  禁止水平切片(先全部 test 再全部 code)。
- TDD:一次一個行為。Red(寫失敗 test、確認失敗)→ Green(最小實作)→ Refactor。
- Behavior test 而非 implementation test:test 讀起來像規格,refactor 後仍存活。
- Tiny commits:每步保持可運行。

## Context 紀律
- context 壓在約 100k token 以下。
- clear 重啟勝過 compact(compact 留沉積物拖垮品質)。
- clear 前由 orchestrator 產出交接內容(當前切片/已驗證事實/下一步/雷區)。

## TDD 適用邊界
red-green-refactor 只在「可立即驗證的程式行為」這層有效(計算邏輯、訊號 gate 布林判斷)。
不適用於需要延遲回饋才能判斷對錯的領域(如投資 thesis 正確性)。
