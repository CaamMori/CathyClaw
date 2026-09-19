# CakeClaw 安全模型

## 双层设计

### 机制层（Docker / 系统强制）
- Gateway 仅监听 `127.0.0.1:18789`，不直接暴露公网
- Nginx 作为唯一外部入口；默认 `limit_conn` 限制每 IP 并发连接（`CONN_LIMIT`，默认 15）
- 容器非 root（`node`），不挂载 docker.sock，非 host network
- cgroup 限制：memory / cpu / pids（默认 PID 上限 1024）
- 密钥经 `env_file` 注入，`runtime.env` 权限 0600

### 约定层（Agent 策略文件）
- `SOUL.md` — 行为契约：管理员任务优先，禁止泄露密钥
- `AGENTS.md` — 风险策略：可逆直接执行，不可逆需确认
- 部署后按环境修改 `templates/` 下模板

## 生产加固建议

1. 部署时自动生成 Gateway Token（已实现）
2. 有域名时启用 HTTPS + Certbot
3. 按需在 Nginx 增加 `allow` 来源 IP 限制
4. UFW：有域名放 80/443，无域名放 8080（安装脚本已处理）
5. 定期 `./scripts/update.sh` 更新镜像
6. （可选）在 compose 增加 `security_opt: ["no-new-privileges:true"]` 与更严的 `cap_drop`
