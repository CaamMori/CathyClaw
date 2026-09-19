# 备份还原能力：实测报告

本文记录"补备份还原、供应链校验、CI 扫描"三项能力的**实测证据**，而非设计说明。
之所以单独成文：这套脚本的缺陷全都属于"看上去在工作"的类型——归档文件存在、
大小正常、日志写着 `backup ok`，可用性却是零。只有实测能区分这两者。

- 仓库：`CaamMori/CathyClaw`
- 测试机：`44.200.155.154`（真实 `/data`、真实 Gateway 容器）
- 生产机：`160.202.238.171:57841`（仅只读比对）
- 验收日期：2026-09-19

## 一、旧版备份为何等于没有备份

重写前的 `nightly-backup.sh` 在测试机上手动执行成功（`exit=0`，归档 72K），
但归档内容与新版对比后，结论是**即使它成功，也还原不出可用系统**：

| 指标 | 旧版 | 新版 |
|---|---|---|
| 归档条目数 | 38 | 1404 |
| 归档大小 | 72K | 25M |
| `data/state/openclaw.json` | 有 | 有 |
| `data/etc/openclaw/runtime.env` | **缺** | 有 |
| `data/state/credentials` | **缺** | 有 |
| `data/etc/openclaw/docker-compose.yml` | 缺（脚本里路径写错） | 有 |
| `usr/local/bin/ensure-telegram-alive.sh` | 缺（脚本里路径写错） | 有 |
| `.sha256` 校验和 | 无 | 有 |
| 缺失路径的可见性 | `2>/dev/null` 全部吞掉 | 显式列出 |

缺的恰好是还原时最要命的两样：`runtime.env`（含 Telegram token）与 `credentials`。
Gateway 能拉起容器，但连不上 Telegram、读不到凭证。**归档在、大小正常、
日志写着 `backup ok`，可用性为零。**

补充事实：测试机上 `/var/log/nightly-backup.log` 在重写前是**空的**，
`/data/state/backups/` 下也没有任何归档——cron 里排着 `17 4 * * *`，
但这个备份从未真正产出过东西。

## 二、正向完整往返（真实机器）

```
① 备份    exit=0，25M / 1404 项，缺失 1 项（/usr/local/etc/mihomo/config.yaml，测试机未装代理，属预期）
② 校验    4 项 [OK]：可解压 / SHA256 通过 / 含核心配置 / 新鲜（0h）
③ 破坏    删除 openclaw.json、runtime.env、整个 agents/ 目录
④ 还原    SHA256 通过 → 快照 25M（3 个顶层路径）→ 停 Gateway/te-daemon/cdp-relay
          → 解包 1404 项 → 修权限 → 重启 → Gateway healthy
⑤ 核验    openclaw.json md5 与还原前逐字节一致（229c0002d5bd1835afcb853ef32b8a9f）
          agents/ 恢复（guest、main）；runtime.env 在位
          归档 sha256sum -c 报 OK —— 未被解包流程改写
```

**第 ⑤ 项最关键**：归档在还原后仍完好。旧实现不做排除时，`tar -xzf` 会命中归档内的
`data/state/backups/...` 条目，把正在读取的归档自身截断（实测 10196 → 0 字节）。
修复方式是在打包与解包两端都排除 `backups` 子树。

## 三、负向测试（6/6 通过）

判据：坏输入必须导致**非 0 退出**，且**不得改动 `/data`、不得产生多余快照**。

| 用例 | 结果 | 输出 |
|---|---|---|
| A 备份目录不存在 | exit=1 | `[FAIL] 备份目录不存在: /nonexistent` |
| B 翻转 1 字节但校验和保持原值 | exit=1 | `[FAIL] SHA256 校验失败——备份已损坏，拒绝还原` |
| C 截断归档（前 5000 字节） | exit=1 | `[FAIL] 归档不可读` |
| D 随机二进制（校验和匹配） | exit=1 | `[FAIL] 归档不可读` |
| E 缺少 `.sha256` | exit=1 | `[FAIL] 无法验证完整性——拒绝还原`，并提示 `ALLOW_UNVERIFIED=1` |
| F 副作用检查 | — | `openclaw.json` 未被改动；快照目录未新增 |

用例 B 尤其重要：它证明校验和验证的是**内容**而非文件名或大小。

### 刻意选择"拒绝"而非"继续"的三处

1. **校验和不符 / 归档不可读** → 拒绝。坏归档解包到一半会留下半毁状态，比不还原更糟。
2. **缺少 `.sha256`** → 默认拒绝。无法证明未被篡改的归档，风险等同来源不明的二进制。
   需要人工承担风险时用 `sudo ALLOW_UNVERIFIED=1 openclaw-restore.sh <归档>`。
3. **无法创建还原前快照** → 拒绝。破坏性操作没有退路就不该开始。

## 四、备份区权限边界

还原脚本修复权限时会 `chown -R 1000:1000 /data/state`，这会连 `backups/` 一起改。
备份区必须归 `root`：容器内 uid 1000 若能改写备份，备份即可被篡改，
基于 sha256 的完整性防线随之失效。实测归位结果：

| 路径 | 权限 | 属主 |
|---|---|---|
| `/data/state/backups` | 700 | root:root |
| `/data/state/backups/config` | 700 | root:root |
| `.../config-*.tar.gz` | 600 | root:root |
| `/data/state/openclaw.json` | 600 | 1000:1000 |
| `/data/state/agents` | 700 | 1000:1000 |

## 五、保留策略与并发

- **保留 7 份**：连续造 10 份备份后，目录内稳定保持 7 份，且为最新的 7 份。
- **并发不覆盖**：同时启动两份备份，总数仍为 7，未互相覆盖（归档名含 PID 后缀，
  避免同一秒内重跑静默覆盖上一份）。

## 六、cron 环境验证

`backup-verify.sh` 在 `env -i`（完全清空环境变量、最小 PATH）下：

- 正常情况：4 项 `[OK]`，exit=0
- `--quiet` 且全绿：**完全静默**，exit=0
- `--quiet` 且最新归档损坏：**输出问题清单 + exit=1**
  （实测揪出"0 字节"与"SHA256 失败"两个独立问题）

"静默模式"的完整含义是**全绿静默、异常必响**。只有前者的话，cron 就是在假装工作。

## 七、附带发现：环境变量缺失导致功能静默失效

排查过程中从 Gateway 日志捞到一条真实故障：

```
[ws] ⇄ res ✗ message.action 348ms errorCode=UNAVAILABLE
PlatformMessageNotDispatchedError: Outbound not configured for channel: telegram
```

根因：`openclaw.json` 里 `channels.telegram.botToken` 写的是 `${TELEGRAM_BOT_TOKEN}`，
而 `runtime.env` 中该键为空。健康检查不覆盖业务通道，所以 Gateway 一直 `healthy`，
安装日志全绿，直到真的发消息才暴露。

已据此新增 `env_health_check()`（安装流程 §12.10，另有 `--env-check` 只读入口）。
在测试机实测输出：

```
openclaw.json 引用了 5 个环境变量，其中 1 个已就绪。

【严重】缺这些会让核心功能不可用：
  - TELEGRAM_BOT_TOKEN
      影响: Telegram 出站消息完全发不出去（Outbound not configured for channel）
      引用位置: channels.telegram.botToken
  - TELEGRAM_OWNER_ID
      影响: Telegram 侧无法识别 owner：allowFrom 与 elevated 工具均失效
      引用位置: agents.entries.main.tools.elevated.allowFrom.telegram[0], channels.telegram.allowFrom[0]

【重要】缺这些会削弱 agent 能力：
  - GH_TOKEN  → sandbox 内访问 GitHub 不可用（git clone/push、gh 命令）
  - TAVILY_API_KEY  → agent 的联网搜索工具不可用
```

## 八、尚未验证的部分

诚实列出，避免高估当前验证覆盖：

- **生产机未做还原演练**。所有往返测试都在测试机。生产机只做过只读比对——
  这正是 `ROOT_PREFIX` 存在的意义：让演练可以离线做，不必反复摧毁线上 `/data`。
- **沙箱镜像构建未验证**。供应链校验（Docker 签名密钥验指纹）已在本地用真实验证过
  4 种输入（真钥通过 / 错误期望值拒绝 / HTML 冒充拒绝 / 空文件拒绝），但完整构建流程未跑通。
- **CI 工作流未在 GitHub 真实 runner 上执行过**。`security.yml` 的 Gitleaks / Trivy /
  TruffleHog 三个 job 尚未首次运行，第三方 action 版本可能需要按实际输出调整。
- **模型调用路径未端到端验证**。Gateway 日志显示 `agent model: openai/gpt-5.6-sol`
  （走内置默认，非 `openclaw.json` 的 `models.providers`），但未实际发消息验证。
