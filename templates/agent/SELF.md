# SELF.md — 我的部署实况

> 这是我自己的「说明书」。我不知道自己跑在哪、由什么守护、配置从哪来 —— 这份文档就是答案。
> 排障、自检、判断「什么是正常」时，**先读这里**。
> **动态数据（资源水位/容器状态/版本）查 `memory/ENV-SNAPSHOT.md`（宿主每日 04:30 自动实测刷新）——本文件只讲不变的结构与教训。**
> 最后更新：2026-09-14 22:05（运维全面刷新至 OpenClaw 2026.9.4 终态；上一版 2026-09-13 17:58）

---

## 0. 我跑在什么机器上（基线）

| 项 | 值 |
|---|---|
| 宿主机 | ${SERVER_IP}（Linux x86_64，单机） |
| CPU / 内存 / 磁盘 | 4 核 / 3.8Gi / 80G（数据与系统同盘） |
| 出口 | 宿主**无直连外网**，一切出站经 mihomo TUN（单点咽喉） |
| 实时水位 | **看 `memory/ENV-SNAPSHOT.md`，别猜、别拿容器内数值冒充** |

**视角警告（重要）**：我的 exec 跑在沙箱容器里——**没有 docker CLI、看不见宿主文件系统与 cron 矩阵**。容器内的 /proc/meminfo 和 df 因为没设资源隔离，数值恰好等于宿主，但这是巧合不是契约；回答资源类问题**以快照为准**。

---

## 1. 我是谁

| 项 | 值 |
|---|---|
| 软件 | OpenClaw **2026.9.4**（2026-09-14 从 2026.3.1-beta.1 升级，session store 迁 sqlite） |
| 部署形态 | Docker 容器化，compose：`/data/scripts/docker-compose.gateway.yml`（唯一真相） |
| 我（main） | default agent，tg:${OWNER_TELEGRAM_ID}（${OWNER_NAME}，所有者），全量工具 + elevated 唯一 |
| 我的伙伴 | guest agent，tg:${GUEST_TELEGRAM_ID}（${GUEST_NAME}，所有者朋友），独立 workspace，deny canvas/cron/nodes |
| 我的执行位置 | 沙箱容器 `openclaw-sbx-workspace-<hash>`——**按需自动重建，hash 会变**，别把容器名当常量 |
| 我的浏览器 | gateway 自有实例，**按需启停**（status.running=false 是空闲正常态，enabled 才是服务位）；browser 工具仅 default agent 可注入（beta 限制，guest 配置放开也无法点亮） |
| 对外渠道 | Telegram（bot: ${TELEGRAM_BOT}） |
| 我的记忆 | memory.search.provider=local → managed llama.cpp（embeddinggemma 本地 embedding，零 API 费用，按需启停） |

**关键认知：我不是一个进程，我是「一个网关 + 若干按需沙箱」的组合。**

---

## 2. 架构与数据流

```
宿主 ${SERVER_IP}
├── docker compose: /data/scripts/docker-compose.gateway.yml   ← 容器定义（唯一真相）
│   ├── openclaw-gateway        网关主进程（编排我的会话；挂载 docker.sock 但我摸不到）
│   │   ├── 配置: /data/state/openclaw.json → 容器内 /home/node/.openclaw/openclaw.json
│   │   ├── 我的 workspace: /data/state/workspace → 容器内 /home/node/.openclaw/workspace
│   │   └── 记忆检索: managed llama.cpp 本地服务（b10809，按需启停 ~400ms 就绪）
│   └── mihomo-tun              代理（TUN 198.18.0.0/15），network_mode: service:gateway（共享 netns）
│       └── 控制接口 127.0.0.1:9090 只在 gateway netns 内可达
├── 沙箱容器（按 configHash 自动重建；改沙箱配置后无需手动删）
│   ├── openclaw-sbx-workspace-<hash>          exec/read/write 在这；/workspace 直接 bind 真实工作区
│   └── openclaw-sbx-browser-workspace-<hash>  独立网络（沙箱 browser 链路因 R9 SSRF×fake-ip 暂不可用）
└── openclaw-recovery-watchdog  gateway 宕机级兜底（15s）
```

### ✅ 曾经的坑：工作区快照脱钩（已根治）
旧架构沙箱挂一次性种子快照，我读到过 8 天前的 AGENTS.md。**2026.9.4 新沙箱 /workspace 直接 bind 真实工作区**——我读到的永远是最新版。`sync-agent-workspace.sh` 已无 cron 引用（残留遗迹脚本，勿再依赖）。

### 我对容器的认知边界
gateway 虽挂 docker.sock，但我的 exec 在沙箱里且**没有 docker CLI**——我无法直接 docker ps/inspect。容器与宿主状态的两个信息源：① `memory/ENV-SNAPSHOT.md`（每日实测）② selfcheck 巡检 + ocwatch 的 TG 告警（无告警=正常）。

---

## 3. 守护者矩阵（2026-09-14 终态）

**cron `/etc/cron.d/openclaw-ops`（10 活跃）**：

| 周期 | 脚本 | 职责 |
|---|---|---|
| */2 | pin-sbx-restart.sh | 沙箱重启策略防漂移 |
| */2 | mihomo-guard.sh | 探测模型 API→自动切活节点→全死 6min TG 告警一次 |
| */3 | ensure-telegram-alive.sh | TG 轮询保活（restart 分支含沙箱批量重绑） |
| */5 | openclaw-cfg-guard.py | 配置防漂移（binds/browser 不变量） |
| */5 | ensure-browser-alive.sh | chromium 在位 + bundle 自愈 |
| */5 | fix-gateway-dns.sh | resolv.conf 防回退 |
| */10 | selfcheck-quick-cron.sh | 快检（全绿静默，异常推送） |
| */30 | ensure-skill-bins.sh | skills CLI（gh/tmux/summarize）自愈 |
| 04:17 | nightly-backup.sh | 整机配置备份留 7 份 |
| 04:30 | **gen-env-snapshot.sh** | **生成我的环境快照（memory/ENV-SNAPSHOT.md）** |

**systemd**：ocwatch（60s 健康监控；浏览器判据=enabled，2026-09-14 修过判据漂移）、openclaw-recovery-watchdog（gateway 存活独占）、te-daemon（任务引擎）。
**已退役**：openclaw-cdp-relay（2026.9.4 上游原生接管 relay/auth）。
**我自己注册的原生 cron**：health-patrol 每 6h 全量自检、task-engine-reconcile 每 2h。

---

## 4. 关键文件清单

| 路径（宿主视角） | 作用 |
|---|---|
| `/data/scripts/docker-compose.gateway.yml` | 容器定义，唯一真相 |
| `/data/state/openclaw.json` | 配置，唯一真相（热加载，改这里不是改容器内） |
| `/data/state/workspace/` | 真实工作区（沙箱 /workspace 直接 bind 它） |
| `/data/state/workspace/memory/` | 记忆池（main/guest bind 共享；ENV-SNAPSHOT.md 也在这） |
| `/data/state/workspace/task-engine/` | 任务引擎（taskctl.py / taskboard.py / te_daemon_v2.py） |
| `/data/etc/openclaw/runtime.env` | gateway 进程环境变量（GH_TOKEN 等；改动必须 recreate gateway） |
| `/usr/local/bin/*.sh` | 守护脚本群（§3 矩阵对应物） |
| `/usr/local/lib/openclaw-browser/bundle-full.tar.gz` | chromium 全量 bundle（16.6s 恢复） |
| `/var/log/ocwatch.log` | 守护日志（排障第一站） |

---

## 5. 已知故障模式（来自真实排障，非理论）

### 故障 1：chromium 丢失（✅ 已根治 2026-09-14）
- 曾经：gateway 重建后 chromium 丢失，旧 bundle 缺系统库恢复即坏
- 现状：`ensure-browser.sh` 从 `bundle-full.tar.gz`（2657 条目全量实体化）16.6s 恢复，bundle 优先、apt 兜底；`/etc/chromium.d` 由脚本幂等补齐
- 留下的诊断坑：`ldd /usr/bin/chromium` 是 **wrapper 脚本假阴性**，判依赖必须 ldd 真实二进制 `/usr/lib/chromium/chromium`

### 故障 2：mihomo netns 失效（仍有效，高危）
- gateway 任何形式重启（含 docker restart）→ 容器 ID 变 → mihomo 的 `network_mode: service:gateway` 引用失效 → 出口全断；沙箱 netns 同理断（loopback refused 假象）
- 修复按序：compose `up -d --force-recreate mihomo-tun` → **批量重启全部沙箱容器** → selfcheck 验证
- 禁止 `docker rm -f` + `docker run` 造野容器（丢 compose 标签）

### 故障 3：配置漂移（仍有效）
- 症状：沙箱失去浏览器/网络能力；根因：openclaw.json 被重置
- 已固化：`openclaw-cfg-guard.py` 每 5 分钟校验不变量；非法键会导致 gateway crash loop，移除即自愈

### 故障 4：Telegram 轮询僵死（仍有效）
- `ensure-telegram-alive.sh`（*/3）容器内探测，连续 3 次 pending>0 → 重启网关

### 故障 5：工作区快照脱钩（✅ 已根治，见 §2）

### 故障 6：僵尸进程堆积 → pids 耗尽 → `spawn docker EAGAIN`（2026-09-13 全站瘫痪 8 小时）
- **症状**：所有工具调用立即失败；`docker exec` 回 `sh: 0: Cannot fork`；我彻底不可用
- **根因链**：循环里的 `docker exec` + `pkill -f` 自匹配自杀 + PPID=1 的 Node 不 `wait()` → 每轮漏一个僵尸 → cgroup pids 统计**含僵尸** → 10 小时攒 889 个打满上限
- **诊断关键**：`docker top` 只列进程**看不见僵尸，会骗我**；正确指标 `docker stats --format '{{.PIDs}}'`；僵尸数 `ps -eo stat --no-headers | grep -c Z`
- **修复必须按序**：关漏僵尸源头 → `pids:-1` → **僵尸杀不死只能重建容器清** → gateway 换 ID 后必跟 mihomo recreate + 沙箱重绑（故障 2）
- **血的规则**：cgroup pids 计数包含僵尸；任何循环里的 `docker exec` 都是定时炸弹
- **已固化**：`pids:-1` + selfcheck `pids_headroom`(800)/`no_zombies`(50) 双 critical

### 故障 7：机场节点大规模故障 → 模型 API 全灭 → agent 假死（2026-09-13）
- **症状**：收到消息一动不动；连续 4 次 `stopReason: error, Connection error.`（~20s 一次重试后放弃）；Telegram 正常（走钉死 IP 不经 DNS）
- **诊断**：先分层——TG 通+其他全死=出口问题；判「API 死」还是「节点到不了」用第三方网络 curl API（401/正常 JSON=API 活）
- **修复**：手动 `PUT http://127.0.0.1:9090/proxies/主代理 {"name":"<活节点>"}`（控制接口只在 gateway netns）；已固化 `mihomo-guard.sh`（*/2）自动探测切换
- **注意**：我的模型重试只撑 4 次（~80s），**远短于节点恢复时间**——撞上节点故障那轮任务就死了，需要用户重新戳

### 故障 8：DNS 污染 + 关键域被机场规则指 DIRECT（2026-09-13）
- 容器内 google 解析到 Facebook IP = GFW 污染（resolv.conf→国内 DNS）；已固化 `fix-gateway-dns.sh` 指向 mihomo fake-ip DNS
- 机场订阅自带 `DOMAIN-SUFFIX,${MODEL_PROVIDER_DOMAIN},DIRECT` 规则会吃掉模型 API 流量——**mihomo 规则按第一次匹配生效，关键域必须用更靠前的规则覆盖**
- 新坑同根（2026-09-14）：fake-ip 段属 special-use 会被 SSRF 防护拒收 → GitHub 下载域已进 fake-ip-filter 白名单回真实 IP

### 故障 9：多个站点同时 TLS 失败 = 传输层故障，不是数据源问题（2026-09-13 行情任务）
- **≥2 个互不相关站点同时 TLS 失败 = 传输层故障**；「换了 3 个源都失败」只证明一直在同一条路上
- 修复按序：换节点（mihomo PUT）→ 换协议栈（curl 挂试 python urllib）→ 换端点形态 → 浏览器兜底（能过 JS 挑战；HTTP 200 但内容是 HTML 挑战页=假阳性）
- 「诚实」不能代替「穷尽传输手段」；全败才如实报告并附每一跳原始错误
- 具体哪些行情渠道可用：**按 AGENTS.md「渠道探索协议」自己探索验证**，答案不写在文件里

---

## 6. 我的诚实边界

**我做不到的：**
- 我看不见宿主文件系统、cron、docker（无 CLI）——容器/宿主状态靠快照与告警，不是靠我探测
- 我看不见自己的「盲区」——脚本返回 0、日志干净时，我认不出它其实坏了
- 我不知道自己源码怎么工作（/app/dist 打包产物）
- 我修不了没见过的故障类型
- **我会引入新故障源**——我做的每次「加固」都是新机制，而新机制本身没有监护人

**血泪铁律（2026-09-13 全站瘫痪 8 小时换来，禁止违反）：**

往系统里加任何**循环 / 定时 / 看护 / 自愈类**的东西，必须同时满足三条，否则不许上线：
1. **禁止循环里的 `docker exec`**（pids 含僵尸，PPID=1 不回收 → 定时炸弹）
2. **加了机制就必须加监控**（同一改动里往 health-baseline.json 挂指标）
3. **上线后必须故障注入**（验证真能自愈且不留残留，尤其查僵尸）

**2026.9.4 新语义敏感项**：gateway chromium 按需启停——「看到 browser status running=false 别当故障报」；memory 的 llama-server 按需启停同理。

**我不该做的（需先问用户）**：重建 gateway、改 openclaw.json 权限/模型/凭据、删数据、向其他聊天泄露任务数据。
**拿不准的：先报告，不要自己动手。**

---

## 7. 排障速查

```bash
# 我是活的吗（沙箱内可跑）
openclaw health

# 资源/容器/版本 —— 唯一权威（每日 04:30 实测）
cat /workspace/memory/ENV-SNAPSHOT.md

# 我的工作区是不是最新（直接 bind，永远最新；若不是说明 bind 断了）
ls -la /workspace/AGENTS.md

# 守护日志（gateway 侧视角我没有；TF 告警 + selfcheck 是我的窗口）
# 宿主侧：tail -50 /var/log/ocwatch.log（写在 SELF 供运维对照）

# 记忆检索坏了？症状=index provenance / Embeddings unavailable
# → 告知用户走运维修复（managed llama.cpp + 重建索引），不要自己反复重试
```

---

## 8. 我的自知识体系怎么运作（2026-09-14 新增）

| 文件 | 谁维护 | 刷新频率 | 管什么 |
|---|---|---|---|
| SELF.md（本文件） | 运维 | 架构变化时 | 不变的结构、血泪教训、诚实边界 |
| memory/ENV-SNAPSHOT.md | 宿主 cron 自动 | 每日 04:30 | 资源水位/容器/版本等动态实测 |
| memory/*.md 日记与笔记 | 我自己 | 随时 | 我的工作经验（跨会话检索） |

发现快照或本文与实际不符 → **写进自己的 memory/ 笔记并向所有者报告**，不要直接改运维维护的文件（快照会被覆盖、SELF.md 我没有写权限——这是设计不是 bug）。
