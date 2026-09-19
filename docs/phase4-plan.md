# Phase 4 — 多节点与高可用

> **当前状态**: `failover.sh` 单机备援可用（同机启动 fallback 容器），`sync.sh` rsync 可用。
> 以下能力仅有客户端脚本，Gateway 端 `/api/workers/*` `/api/tasks/*` 接口需 OpenClaw 版本支持或自定义扩展。

## 已交付（单机可验证）

| 脚本 | 功能 | 限制 |
|------|------|------|
| `failover.sh` | 主备切换（local fallback） | 同机不同端口 |
| `sync.sh` | rsync 增量备份到远程 | 需配置远程 rsync 目标 |

## 客户端脚本（需 Gateway 端对应 API）

| 脚本 | 功能 | 依赖 Gateway 接口 |
|------|------|------|
| `worker-register.sh` | Worker 向 Master 注册 | `POST /api/workers/register` |
| `master-discover.sh` | Worker 心跳 + 发现 | `GET /api/workers/heartbeat` |

> 以上 Gateway API 在当前 OpenClaw 镜像中未发现对应实现。
> 这些脚本是**设计稿配套的客户端代码**，待 Gateway 支持后可用。

## 架构（设计目标）

```
master (cakeclaw-gateway)
  │
  ├── worker-01 (primary VPS)
  ├── worker-02 (second VPS, when available)
  └── worker-N ...

注册:  worker-register.sh → POST /api/workers/register  ⚠️ API 待实现
心跳:  master-discover.sh  → GET  /api/workers/heartbeat ⚠️ API 待实现
备份:  sync.sh             → rsync /data/backups → remote ✅
切换:  failover.sh         → local fallback 或 remote SSH 拉起 ✅ (单机)
```

## 任务分发（设计草案）

```
路由:
  标签匹配 → worker.labels ∩ task.tags
  负载均衡 → 当前活跃任务数最少的 worker
  亲和性   → 同 session 优先同 worker

分发:
  master → POST /api/tasks/assign → worker 执行  ⚠️ API 待实现
          ← POST /api/tasks/result ← worker 返回  ⚠️ API 待实现
```
