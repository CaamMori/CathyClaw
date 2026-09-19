# 本地任务引擎

标准库实现的最小本地任务执行器：任务元数据与日志持久化在 `tasks/<id>/`，运行命令使用显式 argv（不经过 shell）。

```bash
# 创建时登记验收命令（推荐：后续 verify 无需再猜"该怎么验"）
./taskctl.py create '目标' '验收说明' --id demo --accept-cmd "test -s out/result.json"
./taskctl.py run demo --timeout 30 -- python3 worker.py
./taskctl.py status demo

# 验收三选一
./taskctl.py verify demo                     # 跑 create 时登记的验收命令（推荐，有证据）
./taskctl.py verify demo -- test -s out/x    # 临时指定命令
./taskctl.py verify demo --accept            # 人工裁决：不跑命令，直接标记通过

./taskctl.py reset demo                      # 验收失败后重开（verification_failed 可逆）
./taskctl.py list
```

`run` 成功后状态为 `awaiting_verification`，只有显式 `verify` 成功才为 `completed`。运行输出写入任务目录，不写 stdout；JSON 原子替换且权限 0600；同任务使用 flock 防并发。worker 脱离客户端进程并保存 PID，超时只终止其自身子进程组。

边界：本地客户端退出后可继续；不保证 `/new`、Gateway 或容器重启后继续。不提供沙箱，也不能执行外部工具策略；不自动重试或恢复副作用。PID 孤儿恢复采取保守策略，不盲杀 PID 重用进程。

测试：`python3 -m unittest discover -s tests -v`

## 真實產物與新進程接手
接手流程見 HANDOFF.md；已驗證JSON實際內容、SHA-256、文件缺失/損壞拒絕及明確修復後重驗。README早期 `pass`/返回零僅為CLI語法示範，不可作業務驗收。

## 驗收鐵律（2026-09-19 新增，務必遵守）

1. **收到人工「驗收通過」後必須在 1 次工具調用內關閉任務**，禁止用自然語言反覆討論「該怎麼驗收」。
   驗收命令可用 → `verify <id>`；命令失效或找不到 → `verify <id> --accept`。
2. **驗收失敗不要空轉重試**：`reset <id>` 回到 `awaiting_verification` 後重來，或 `--accept` 交人工裁決。
   `verification_failed` 可逆，一次失敗不會報廢任務。
3. **禁止用無條件成功命令冒充驗收**（如 `true`、`python3 -c 'raise SystemExit(0)'`）。驗收必須檢查真實產物或行為。
4. **驗收命令不要放 `/tmp`**（會被清理，導致驗收必然失敗）。放任務目錄或 `artifacts/` 等持久化位置。
5. 只有 `awaiting_verification` 狀態可驗收。先 `status <id>` 確認，必要時 `reset` 後再驗。

> 背景：2026-09-19 `notify_e2e` 因驗收腳本 `/tmp/n.sh` 被清理、且當時 `verification_failed` 不可逆，
> agent 不敢發起驗收而空轉 **6.18 天**，網關日誌中該任務零出現。本鐵律與 `--accept` / `reset` 即為該事故的修復。
