# Gotchas - OpenClaw Production Deployment

> Every entry from a real incident or real reproduction, not speculation.
> 经验法则不是教条——你的环境可能不同。

---

## 0. 最高原则：沉默 ≠ 确认

- 没有报错不代表成功；`doctor` 没报 WARNING 不代表正常
- 有效证明 = **一行可观察证据**：`Memory index updated`、`config hot reload applied`、`outbound send ok`
- 把「我觉得好了」替换为可粘贴的证据行
- `exit 0` ≠ 配置正确，只代表进程没崩溃

---

## 16. Compose entrypoint 变量插值陷阱

- Docker Compose 对 entrypoint / command / env 里的 `$VAR` 做**独立预处理插值**，不认 YAML 块标量
- 裸 `$S` 被当成 Compose 环境变量、因宿主机无该变量而替换为空串
- **必须用 `$$S`**（`$$` 在 Compose 中转义为字面 `$`，渲染后保留给容器内 shell）
- 反例：`if [ "$S" != "healthy" ]` → 实际变成 `if [ "" != "healthy" ]`（恒真 → watchdog 误重启）
- `$(date)` 等命令替换不受影响（Compose 不处理 `$(...)` 语法）
- 验证：`docker compose config` 渲染后 grep 应含 `$S`，否则已被吃空

---

## 1. AGENTS.md 信息架构

- **单文件注入有硬上限**（~20K chars，从尾部截断）——被截的往往是运维核心规则
- **正确做法 = 索引，不是删除**：AGENTS.md = 身份 + 铁律 + 文档索引；细节下沉到 runbooks
- **迁移后逐行回读**：「标题存在」≠「内容存在」
- **查过期**：HEARTBEAT.md / TOOLS.md 在官方文档已 RETIRED，别补丁过期协议

---

## 2. 身份与注入

- 「Agent 认不出用户」= 两层独立故障：能不能读到文件？文件里有没有内容？
- 身份信息必须放在**保证注入层**（AGENTS.md 头部），「读文件 X」不可靠
- 权限授予 ≠ 身份可见，两个问题

---

## 3. 无回复两段式排查法

- Model status=200 但无 `outbound send ok` = **投递段**断了（查 egress/proxy）
- 只探测 api.telegram.org 有假阳性，应改用 gstatic.com/generate_204
- mihomo PATCH 返回 204 ≠ 配置已生效，必须 GET /proxies/<group> 确认 active
- **放大器**：interval=300 意味着死节点要 5 分钟才切换

---

## 4. 响应速度三大原因

1. **重复规则 = 隐形杀手**：mihomo 按顺序匹配，第一条命中即停；后面写了更优节点也没用
2. **DNS SERVFAIL**：`getent hosts` 返回空 ≠ 没有 DNS——发一次 DNS 查询，查 rcode
3. **idle watchdog 120s**：云厂商安全组/ALB 空闲超时

---

## 5. TTFT 不是慢，是不稳定

- 中位 ~1.5s，但 ~13% 跳到 17-30s（最差 133.9s）
- 跨境链路 ~10% 失败率——物理限制，不接受「修复」
- **应对**：streaming partial，timeoutSeconds 设 40

---

## 6. DNS 自环死锁（TUN 模式经典坑）

- mihomo DNS 查询命中自身 proxy 规则 → 死锁
- **解法**：/etc/hosts 静态绑定 + compose extra_hosts
- API 域名必须在 GEOIP/CN 规则之前

---

## 7. 缓存与性能

- 预热：22% → 96%（5 次请求后）
- 上下文悬崖：8 tokens 1.7s，33K → TLS 超时
- compaction 死锁：99% 容量时所有消息被阻塞
- **compaction model 必须单独配置**，轻量模型

### 7.1 compaction 死锁（永久阻塞）

- Session 达到 ~99% → **所有消息永久阻塞**
- 默认复用主模型（太慢）
- 超时：默认 180s（源码常量 EMBED_COMPACTION_TIMEOUT_MS = 18e4）
- **决策**：用 contextWindow 大的模型（从 20 次 compact 降到 1 次）

---

## 8. 安全与凭据

- openclaw.json → chmod 600
- `${ENV}` ≠ 审计去密，只缩小磁盘暴露
- 配置热加载 → 等「config hot reload applied」，永远不要 kill -s HUP
- **sandbox uid 必须匹配 workspace owner**（1000:1000）
- Gateway 不能 root 运行（uid 不匹配 sandbox）
- uid 不匹配：read 可写，write 失败

---

## 9. refactoring 教训

- 「workspace」：先确认是 sandbox 路径还是 server 路径
- cp -a 再覆盖
- Remote relay → base64 + md5 两端校验
- 破坏范围不确定 → 先问

---

## 10. 方法论（17 条铁律）

1. 延迟要分层测（host / container / chain）
2. 无回复两段式排查（model / delivery）
3. DNS 用 rcode 不用 getent
4. 特征值定层
5. 测试先验证测试本身
6. 看趋势不看快照
7. 沉默 ≠ 确认
8. 修 A 暴露 B
9. 补丁前查规范
10. 迁移后重新读输出
11. cp -a 再覆盖
12. relay 用 base64+md5
13. 僵尸锁：0 字节 + 无进程
14. 重启残留孤儿 netns
15. 说明物理限制
16. 位置 ≠ 可用性
17. 过期记忆用当前源更新

---

## 11. DNS self-loop (TUN mode)

- mihomo DNS query -> hits own proxy rules -> DoH outbound -> needs DNS -> deadlock
- Fix: /etc/hosts static bindings + compose extra_hosts
- Rule: check fake-ip-filter before touching SSRF config

---

## 12. Compaction deadlock (99% capacity permanent block)

- Session at ~99% -> all messages permanently blocked
- Default reuses main model (too slow)
- Timeout: 180s default (EMBED_COMPACTION_TIMEOUT_MS = 18e4)
- Fix: use large contextWindow model for compaction, drop from 20 to 1 compaction

---

## 13. Sandbox uid mismatch = silent write failure

- Container uid 1000(node), file owner root -> kernel denies
- `ls -l` shows 755 looks normal, but uid 1000 only gets r-x
- Fix: chown -R 1000:1000 /data/state/workspace
- Never use user: root to bypass

---

## 14. Sandbox browser bypasses TUN

- Browser sandbox on isolated network 192.168.32.0/20
- Default goes through host bridge, not mihomo TUN
- OpenClaw chrome.ts hardcodes --no-proxy-server when no proxy configured
- Fix: inject --proxy-server in image, don't touch SSRF config

---

## 15. Config hot reload != immediate effect

- After changing openclaw.json, wait for "config hot reload applied" log
- mihomo PATCH 204 != config applied, must GET to confirm
- Rule: exit 0 != config correct, just means process didn't crash
