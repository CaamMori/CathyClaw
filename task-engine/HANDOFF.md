# 本地任務接手協議 v1

適用：受信任單用戶工作區的已授權本地命令。不是多租戶隔離，不得用於繞過工具审批。跨CLI進程接手不等於已驗證聊天 /new 或容器重啟。

## 每項任務的接續記錄
- 所屬私聊（不可將其他使用者任務內容曝光）
- task ID、TASK_ENGINE_HOME 的絕對路徑
- 目標、產物絕對路徑
- 執行 argv 與超時
- 驗收 argv、判定標準；禁止無條件成功
- 已完成步驟、下一步、不可重複的副作用

## 新執行進程接手
1. 讀取 checkpoint 與這份協議。
2. 使用相同 TASK_ENGINE_HOME 執行 `python3 taskctl.py status TASK_ID`。
3. running：觀察，不再次 run；不要從 PID 猜測成功。
4. awaiting_verification：檢查產物，執行原先定義的真實驗收。
5. completed：查驗收記錄和產物；不重跑原命令。後續文件可能被修改，重要交付需再次核對內容。
6. failed/timeout/verification_failed：檢查日誌，制定最小修復。在原授權內才可明確重跑；有副作用時先確認沒有重複影響。
7. orphaned：只表示 worker 身份失配；禁止盲殺PID或自動恢復，需要檢查子任務是否仍在執行。

## 可重跑接手驗收
`python3 -m unittest discover -s tests -p test_handoff.py -v`
- 客戶端退出後，後台生成 JSON；另一CLI進程以內容及SHA-256驗收。
- 阻止待驗收任务重复run，用文件mtime验证没有重新生成。
- 破壞文件驗收失敗；明確修復後重新驗收成功。
- 文件缺失必須驗收失敗。

## 仍未覆蓋
- 真實 /new 與 Gateway/容器重啟。
- 單任務多步驟自動排程、持久通知 watchdog、跨使用者ACL。
- 任務命令可使用該進程權限，沒有OS沙箱，不能安全運行不可信代碼。
