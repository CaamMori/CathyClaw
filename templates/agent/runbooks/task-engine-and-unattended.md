# Runbook：任务引擎与无人值守运维

> 从 AGENTS.md 下沉（2026-09-16）。**使用 taskctl / 看板 / 排查后台任务时读这个文件。**

---

## 1. Local task runner

已授权、适合本地执行的长命令可用 `task-engine/taskctl.py`：`create` → `run` → `status` → `verify`。
**先读 `task-engine/README.md`。**

- **不得**用它绕过 exec 审批、安全限制或发送外部消息。
- 将 task ID、`TASK_ENGINE_HOME`、产物、验收命令及所属私聊写入 checkpoint。
- 新会话先查 status，**不重复 run**；不得向其他用户展示任务数据。
- 当前版本**只限受信任的单用户使用**。
- **`completed` 只表示提供的验收命令通过**，主代理仍需审查测试是否覆盖目标（见 `delivery-and-verification.md` §3-4）。
- **验收必须检查真实产物/行为**，禁止以无条件成功命令冒充业务验收。
- orphaned/失败任务**先查证再人工决定恢复，不自动重试副作用**。
- 该工具**不是沙箱或 watchdog**；不保证 Gateway/容器重启存活。
- **验收铁律**：处于 `awaiting_verification` 的任务，收到人工「验收通过」后**必须在 1 次工具调用内关闭** —— `verify <id>`；验收命令失效或找不到时改用 `verify <id> --accept`（人工裁决，不跑命令）。**严禁**反复推理「该如何验收」而不发起工具调用。验收失败用 `reset <id>` 重开（可逆，一次失败不会报废），不要空转重试。详见 `task-engine/README.md`「验收铁律」。

---

## 2. Unattended operation — 定时自主干活

### 周期自检（已配置，无需维护）

Gateway cron 里有两个任务：

| 任务 | 频率 | 职责 |
|---|---|---|
| `health-patrol` | 每 6 小时 :00 | 执行 `bash /home/node/.openclaw/workspace/oc-patrol.sh`，把脚本输出**原样**作为最终回复（**不要改写、不要加前后缀**），结果自动 announce 到 Telegram |
| `task-engine-reconcile` | 每 2 小时 :15 | 检查任务队列有无孤儿/待验收/失败任务；一切干净时只回 `任务队列正常`，否则简短列出「任务id + 状态 + 建议动作」 |

### 看板与汇报

- **看板网页**：http://${GATEWAY_LAN_IP}:8080/board/ （只读，30 秒自动刷新）。给人看的进度入口。
- **手动汇报**：`python3 task-engine/taskboard.py --telegram`（默认发给 ${OWNER_TELEGRAM_ID}）。
  单任务汇报用 `--one <id>`；只看不推用 `--summary`。

### 沙箱说明

- `agents.defaults.sandbox.mode=all`，exec/read/write 都在隔离容器里跑。
  容器内 workspace 即 `/workspace`（对应宿主 `sandboxes/agent-main-*`）。
- **live 任务引擎已通过 bind 挂载到 `/workspace/task-engine`**（与宿主 `/data/state/workspace/task-engine` 是同一份真实目录），
  故 `task-engine/taskctl.py` / `task-engine/taskboard.py` / `task-engine/te_notify.sh` 在沙箱内可直接调用，
  且与 te-daemon 监控、看板共享同一份任务数据。
- **超时**：`agents.defaults.timeoutSeconds=3600`，单个任务最长可跑 1 小时。
  超过仍需更久的活，拆成多个可独立验收的 taskctl 任务，不要硬扛。

---

## 3. Task observability 与接续

- **看板**：`python3 task-engine/taskboard.py` 列出所有任务状态（人类可读）；
  `--json` 机器可读；`--summary` 只列进行中。回答"他现在在干嘛"用它或 `taskctl.py list`。
- **Telegram 简洁汇报**：`task-engine/te_notify.sh <id> [--artifact PATH]` 只推
  「状态 | 目标 | 耗时 | 产物」，**绝不推过程日志**。任务进入
  awaiting_verification / completed / failed / orphaned 时调用一次。
- **后台守护 te-daemon**（systemd，常驻）：每 30s reconcile 一次 ——
  - running 任务超 10 分钟日志无增长**且心跳过期** → 推送「⚠️ 任务疑似卡住」；
    若心跳仍新鲜（长下载/编译在跑）→ 仅记 `QUIET`，**不误报**
  - 进入 awaiting_verification → 推送一次待验收提醒
  - 出现 orphaned → **自动收敛为 failed(-9)** 并推送一次（不自动重跑，交人工/代理决定）

  该守护**只观察与提醒**，不执行有副作用的自动恢复。

---

## 4. 委派子任务的记录要求

派发时将以下内容写入 checkpoint（`TASK-CONTINUITY.md`）：
- 子任务 sessionKey / runId
- 产物位置
- 验收命令
- 失败后接手动作

**注意**：事件未送达或运行环境中断**不保证自动恢复**；**不得把 Prompt 规则描述为已经部署的 watchdog**。
需要定时监控时另行获得授权并实际配置验证。
