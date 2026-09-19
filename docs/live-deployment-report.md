# 一键部署实测报告

**测试机**：`<测试机 IP>`（海外 VPS，Ubuntu，2 vCPU / 3.8 GB RAM / 77 GB 盘）
**测试方式**：清空全部 `/data`、容器、systemd 单元、cron，模拟**全新机器**后执行一键部署
**结论**：✅ 通过 —— 从零到 Gateway `healthy` 全流程跑通

---

## 一、验收结果

| 项目 | 结果 |
|---|---|
| Gateway 镜像 | `ghcr.io/openclaw/openclaw:2026.9.4`（与生产机一致） |
| Gateway 健康 | `healthy` |
| Gateway 就绪日志 | `[gateway] ready`、HTTP 服务监听、13 个插件加载 |
| 浏览器服务 | `Browser control service ready (profiles=3)` |
| 常驻服务 | `ocwatch.service` active、`openclaw-cdp-relay.service` active |
| bind mount | 5 个（workspace / patches / state / docker-cli ×2） |
| 运维矩阵 | `/etc/cron.d/openclaw-ops` 12 条排期 |
| 启动补丁 | `entrypoint.sh`、`apply-maxtoolcalls-patch.sh`、`lock-cleanup.sh` 均已就位并生效 |
| `/usr/local/bin` 运维脚本 | 20 个 |
| 出口判定 | 正确识别为海外机 → 跳过 mihomo，直连出海 |

生产机对照项（镜像版本、常驻服务模型、补丁机制、运维矩阵、sandbox 镜像来源）均已对齐。

---

## 二、本次实测暴露并修复的 6 个真实缺陷

实测的价值就在这里 —— 这些问题在静态审查里全都看不出来。

### 1. `openclaw.json` schema 嵌套错误（导致无限重启）

`agents.defaults.fallbacks` 放错了层级，Gateway 直接拒绝启动：

> `openclaw.json:27 — agents.defaults: Unrecognized key: "fallbacks"`

生产机的正确结构是嵌在 `model` 下。已修正模板，并新增**结构化清洗**逻辑：
- 旧模板残留在顶层的 `fallbacks` 自动并入 `model.fallbacks`
- `${FALLBACK_MODEL}` 未配置时**整条删除**，避免生成非法的 `fallbacks: [""]`
### 2. `install.sh` 回退到了过期版本 `2026.7.1`

`.env.example` 写的是 `2026.9.4`，但 `install.sh` 里两处兜底值仍是 `2026.7.1`。
**没有 `.env` 的全新一键部署会拉到旧版本**，于是：

- 旧版 schema 不认新版配置 → `agents: Invalid input`
- 旧版读不了新版写的状态库 → `schema version 17; this build supports 1`

已把两处兜底值改为与模板一致。

### 3. `.env` 行尾注释被当成值的一部分

模板里这行：

```
DOCKER_GROUP_ID=999  # stat -c '%g' /var/run/docker.sock
```

加载器不剥离 `#`，于是整串成了变量值，Docker 直接拒绝启动整个 stack：

> `unable to find group 999  # stat -c ...: no matching entries in group file`

修复：模板把说明挪到独立行；加载器**只在「空白 + #」时剥离注释**（值里的字面 `#`，
如 `PASS=a#b`，不受影响）；`DOCKER_GROUP_ID` 增加数字校验，非法值自动回退到实测 socket 属组。

### 4. `docker-cli` 包装非幂等（重跑即坏）

第二次安装报：

> `/data/opt/docker-cli/docker: Is a directory`

`cp` 的经典陷阱：首次运行创建了文件，重跑时 `cp` 遇到已存在的**目录**会往里拷而不是覆盖。
顺带发现一个潜伏 bug：包装脚本里 `exec` 的是 `/usr/local/bin/docker.real`，
而真实安装路径是 `/data/opt/docker-cli/docker.real` —— 沙箱内 docker 本会失效。

修复：写入前强制 `rm -rf` 目标（`-rf` 同时清掉历史遗留的畸形目录）；路径纠正；
宿主 docker 改为扫描候选并要求「是真实可执行文件」，不再可能选中目录。

### 5. `ocwatch` 在未配 Telegram 的机器上崩溃重启

`ocwatch.sh` 在 `set -u` 下引用了生产机专有变量：

```bash
ALERT_TARGET="${OCWATCH_ALERT_TARGET:-${OWNER_TELEGRAM_ID}}"
```

新机器上 `OWNER_TELEGRAM_ID` 未定义 → 启动即 `unbound variable` 退出，
systemd 每 5 秒重启一次（实测重启计数已达 26+）。已为两侧都补上默认值
（留空 = 仅记日志，`alert()` 本就支持）。

### 6. 旧容器挂载类型固化，导致 OCI 启动失败

修复第 4 条后，宿主侧 `/data/opt/docker-cli/docker` 由目录变成了文件，
但**既有容器**当初记录的是目录类型，Docker 无法调和：

> `error mounting ".../docker" ...: not a directory: Are you trying to mount a directory onto a file (or vice-versa)?`

容器以 **exit 127** 退出 —— 这个码读起来像「命令不存在」，完全指不到真实原因。

修复：`install.sh` 在启动前比对既有容器每个 mount 的源/目标类型，不一致就删除容器让 compose 重建。
旧容器可自愈，不需要用户去解读 OCI runtime 错误。

---

## 三、第二轮实测（task-engine 对齐后）：又暴露 5 个缺陷

第一轮验收通过后，为「近期改动对齐到项目」做了干净重装，**又抓出 5 个真实缺陷**。
其中 3 个属于同一类：**顺序依赖**——代码没错，但执行次序错了，静态审查与
单次跑通都发现不了。

### 7. `docker-cli` 包装安装晚于 `compose up`（exit 127 崩溃循环）

`compose up` 在 §6（行 651），但包装脚本由 §10.7 的运维组件块写入（行 914）。
全新机器上：

1. §6 `up -d` 时 `/data/opt/docker-cli/docker` **尚不存在** →
   Docker 按挂载目标形态**自动创建成一个目录**，并把类型固化进容器定义
2. §10.7 `rm -rf` + `cat >` 把它**重写成文件**
3. 此后容器与宿主对同一 bind mount 的类型**永久不一致**，任何重启都在
   container-init 阶段失败：

> `error mounting "/data/opt/docker-cli/docker" ...: not a directory: Are you trying to mount a directory onto a file (or vice-versa)?`

以 **exit 127** 退出，读起来像「命令不存在」。

首轮验收通过是因为它只验证「容器 running」——而**首次 up 是成功的**，损坏由
install.sh 在容器建好之后自己制造。纯启动期自愈无法覆盖。

修复：抽出 `install_docker_cli()`，在 §6 `compose up` **之前**调用；§10.7 只做幂等刷新。
另加**事前预检**：compose 中目标位于 `/usr/local/bin`（必须是文件）的 bind，
若宿主侧实为目录，先删掉陈旧容器，让本次 up 按正确类型重建——可修复存量机器。

### 8. 包装脚本硬编码宿主路径，沙箱内 docker 完全不可用

包装脚本 `exec` 写死绝对路径：

```sh
exec /data/opt/docker-cli/docker.real "$@"
```

但**同一个文件在两个视角下路径不同**：

| 视角 | docker.real 位置 |
|---|---|
| 宿主 | `/data/opt/docker-cli/docker.real` |
| 容器/沙箱 | `/usr/local/bin/docker.real` |

于是容器内每次调用都失败：

> `/usr/local/bin/docker: 3: exec: /data/opt/docker-cli/docker.real: not found`

修复：改为按自身位置解析 —— `exec "$(dirname "$0")/docker.real" "$@"`，
两个挂载视角下都成立。已用绝对路径 / 相对路径 / PATH 三种调用方式验证。

> 注：上一轮「修复 4」的注释称写死 `/data/opt` 是为了修掉写死
> `/usr/local/bin` 的旧 bug —— 其实两次硬编码错因相同，都只对了一半。

### 9. `warn()` 被调用 16 次，却从未定义

脚本定义了 `fail/ok/info/step`，**唯独漏了 `warn`**，而全文有 16 处 `warn "..."`。
多数调用位于 `cmd || warn ...` 分支中，`set -e` 不会中断，脚本照常继续，
只在终端留一行 `warn: command not found` —— 极易被当成噪声忽略。

后果：**所有降级/自愈路径都失去可见性**，包括刚加的挂载类型自愈、
沙箱构建失败等。已补齐定义，并写入 stderr 以免污染管道中的 stdout。

### 10. `DOCKER_GROUP_ID` 的数字兜底架空了自动探测

`DOCKER_GROUP_ID` 默认值写死 `999`，而回退到实测 socket 属组的守卫
**只在「值非数字」时触发**。`999` 是合法数字 → 守卫永不执行 → 实测 GID 从未被读取。

Docker 官方包**动态分配** docker 组 GID，实测这台机器是 **988**：

```
宿主 socket        : root:988
compose group_add  : "999"      ← 不一致
容器进程属组       : 1000(node),999   ← 拿不到 socket
容器内 docker ps   : permission denied while trying to connect to the docker API
```

修复：默认留空（由实测决定）；显式数字仍以用户为准，但与实测不一致时告警；
并打印解析结果与实测值便于排查。已验证 6 种组合。

### 11. `te-daemon` 装上了却从未启动（`inactive`）

§10.7 安装 systemd 单元时，启动分支会检查
`[ -f /data/state/workspace/task-engine/te_daemon_v2.py ]`，
但 task-engine 文件**落盘在同一块的更后面** → 检查恒为假 → 单元 `enabled` 却从未
`enable --now`。安装日志只有「systemd 单元已安装」、**没有**「已启动」，
非常容易漏过。

修复：把 task-engine 落盘提前到 §10.7a（早于 systemd 块）。

### 12. 测试套件在负载环境下偶发超时（非功能缺陷）

在已部署机器上跑 task-engine 回归时，偶发 1～2 个用例 `TimeoutExpired`。

排查结论：**环境抖动，不是功能缺陷**。每次 CLI 调用都会新起一个 python
进程且硬超时 5s，而该机器同时跑着 `te-daemon`（30s 一轮 reconcile）、
`ocwatch`、`cdp-relay`，进程启动可能被挤慢。

证据：同一台机器上先出现 2 个失败，紧接着连续 3 次全绿；本地亦 32/32。

修复：超时改为可配置，默认 15s（`TE_TEST_TIMEOUT` 可覆盖）。
**未削弱任何断言** —— 用例自身的行为时限是独立的，不受此影响。
改后容器内连续 5 次运行全部通过（5/5）。

> 顺带澄清一个易误判点：`te-daemon` 读的是自己的 `TE_DIR`（默认生产路径），
> 而测试用 `TASK_ENGINE_HOME` 指向临时目录，两者本就隔离；
> 且 daemon 只做观察与告警、**从不写任务状态**，不可能污染测试数据。

---

## 四、修复清单

```
559c8ea  test: 子进程超时可配置，消除负载环境下的偶发超时
8508ce5  fix: DOCKER_GROUP_ID 数字兜底架空了 socket 属组探测
4e0b652  fix: warn() 被调用 16 次却从未定义
0ed8bb1  fix: docker-cli 包装硬编码宿主路径，沙箱内 docker 不可用
1e1bf41  fix: docker-cli 包装必须在 compose up 之前落位（挂载类型固化）
f873c1e  fix: te-daemon 装上了却从未启动（顺序依赖）
89afeef  feat: task-engine 对齐生产机 R34/R35/R36 加固
2bce895  fix: 旧容器挂载类型固化导致 OCI 启动失败
59dbb4c  fix: ocwatch 在未配 Telegram 的机器上崩溃重启
55d7fab  fix: docker-cli 包装非幂等（重跑即坏）
fb3d667  fix: .env 行尾注释被解析为变量值
c1a6d23  fix: install.sh 回退到过期版本 2026.7.1
a442dc3  fix: openclaw.json schema 嵌套错误 + fallback/telegram 兜底
```

---

## 五、最终验证结果（彻底清空后全新部署）

| 项目 | 结果 |
|---|---|
| Gateway 健康 | `Up (healthy)` |
| 挂载类型 | `docker` / `docker.real` 均为 **regular file** |
| 容器内 `docker version` | `29.8.1`（与宿主一致） |
| 容器内 `docker ps` | 正常列出宿主容器，无 permission denied |
| `group_add` | `988`（= 宿主 socket 实测属组） |
| 容器进程属组 | `1000(node),988` |
| 常驻服务 | `te-daemon` / `ocwatch` / `openclaw-cdp-relay` 全部 active + enabled |
| task-engine | 8 个组件 + 4 个测试文件；属主 `1000:1000` |
| task-engine 回归 | **32/32 通过**（容器内 `unittest discover`，连续 5 次全绿） |
| 泄漏检查 | 0（TG ID / 密码 / 生产机 IP 均无残留） |
| 运维 cron | 13 条 |
| 出口判定 | 正确识别为海外机 → 跳过 mihomo，直连出海 |
| 幂等性 | 在已部署机器上重跑 install.sh：无 FAIL、无 `command not found`、无 `not a directory`，Gateway `healthy`，te-daemon 正常启动 |

### 验证路径（同一台机器，全部重跑过）

1. **首次部署** → 暴露缺陷 1、2、3
2. **修复后重跑** → 暴露缺陷 4、5
3. **再跑（幂等性测试）** → 暴露缺陷 6
4. **彻底清空后全新部署** → ✅ 全绿
5. **task-engine 对齐后干净重装** → 暴露缺陷 7、11（exit 127 崩溃 / te-daemon inactive）
6. **修复 7、11 后再次全新部署** → 暴露缺陷 8（沙箱内 docker 不可用）
7. **修复 8 后再部署** → 暴露缺陷 9（`warn` 未定义）、10（GID 探测被架空）
8. **修复 9、10 后全新部署** → ✅ 全绿 + 32/32 测试通过

第 3 步与第 5～7 步是关键：它们分别证明了**重跑幂等性**与**顺序依赖**这两类
问题，而这两类恰恰只在特定路径上才现形。这也是为什么本报告反复走「清空 → 重装」——
单次跑通不等于可交付。

---

## 六、遗留事项

- **生产机未做任何改动** —— 仍运行其原有的模型 provider 与个人 Telegram 通知配置，本次只做只读审计。
- 测试机上的 Gateway 目前**未配置模型 provider**（无 API Key），
  模型调用链路未验证；需要时在控制台 Config 标签补配即可。
- 该测试机**无法访问 GitHub raw**（拉取沙箱构建文件失败），因此
  `--with-sandbox` 的**镜像构建未验证**；`docker.sock` 挂载与组权限链路已验证通过。
- 测试机密钥来自 `cap.zip`，测完建议轮换或回收。
- 此前泄漏过一个 GitHub PAT（已从代码中清除），建议尽快吊销该 token。
- 仓库提交已推送至远端 `CaamMori/CathyClaw`。

