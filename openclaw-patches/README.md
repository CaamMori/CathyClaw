# openclaw-patches —— 启动期 dist 修改说明

本目录下的脚本会在 **Gateway 容器每次启动时**执行，用于修改上游镜像 `/app/dist` 内的编译产物。

---

## 为什么需要「改上游 dist」这种手段

### 1. 这些行为是上游硬编码的，配置层没有开关

以 `/dashboard` 为例，它和 `help` / `status` / `tasks` 并列注册在同一个命令表里：

```js
// /app/dist/commands-registry.data-<hash>.mjs
defineBuiltinCommand("help", "Show available commands.", "status", "essential"),
defineBuiltinCommand("commands", "List all slash commands.", "status", "power"),
defineBuiltinCommand("tools", "List available runtime tools.", "status", "standard", {...}),
defineBuiltinCommand("skill", "Run a skill by name.", "tools", "standard", {...}),
defineBuiltinCommand("dashboard", "Create or update this session's dashboard.", "tools", "standard", {...}),
defineBuiltinCommand("learn", "...", "tools", "standard", {...}),
defineBuiltinCommand("status", "Show current status.", "status", "essential", {...}),
defineBuiltinCommand("tasks", "List background tasks for this session.", "status", "standard"),
```

这份列表在模块加载时**直接构造**，没有任何 `enabled` / `disabled` 判断。
因此想让它不出现在菜单、不进模型循环，**只能改源码**，改配置是无效的。

### 2. 容器是不可变的，改动每次重启都会丢

镜像重建后 `/app/dist` 回到原始状态。所以修改**不能只做一次**，必须由 `entrypoint.sh` 在每次启动时幂等重放。

这就是 `docker-compose.gateway.yml` 里覆盖 `entrypoint` 的原因：

```yaml
entrypoint: ["/data/opt/openclaw-patches/entrypoint.sh"]
```

### 3. 改动必须 fail-closed，不能 fail-open

脚本靠**字符串精确匹配**定位上游源码片段。上游一升级，片段就对不上。

此时有两种选择：

| 策略 | 后果 |
|---|---|
| fail-open（匹配失败就跳过，照常启动） | 出现「以为已禁用、实际仍会进模型循环」的**不确定状态**，且不报错 |
| **fail-closed（匹配失败拒绝启动）** | 服务起不来，但状态是**确定的**，运维立刻能发现 |

本目录采用 **fail-closed**：`entrypoint.sh` 第 2 步要求删除脚本必须存在且返回 0，否则 `exit 1`。

> 这不是"过于激进"。带不确定行为静默运行的控制面，比一个明确起不来的控制面危险得多——
> 前者会让所有后续排查建立在错误前提上。

---

## 脚本清单

| 脚本 | 作用 | 失败策略 |
|---|---|---|
| `lock-cleanup.sh` | 清理跨重启残留的 0 字节索引锁（会让索引永久停止更新且不报错） | fail-open（清理异常照常启动） |
| `apply-disable-dashboard-command.sh` | 删除 `/dashboard` 聊天命令 | **fail-closed** |
| `apply-maxtoolcalls-patch.sh` | 注入工具调用预算 | fail-open |
| `entrypoint.sh` | 按序调用上述脚本，然后 `exec tini -s -- node openclaw.mjs gateway` | — |

---

## `/dashboard` 为什么必须删除（而不是"修好"或"不用它"）

### 它的危害是主动的

`/dashboard` 生成的地址是**容器内部地址**，对用户的浏览器不可达，因此本身没有使用价值。
真正的问题是它会：

1. 进入 LLM 与工具循环；
2. 尝试读取不可达的 protected Skill 路径；
3. 调用会超时的浏览器控制链；
4. **长时间占用同一个 Telegram session**。

第 4 点是致命的一环：session 被占住后，后续命令全部排队，用户看到的现象是
**「发什么都没回复」**——而不是"某个命令不好用"。故障现象与根因离得很远，排查成本极高。

### 删除做了什么（四处，全部实测生效）

脚本对 `/app/dist` 下的四类模块做幂等修改：

**① 删除菜单注册** —— `miniapp-api-*.mjs`

```js
function registerTelegramMiniAppCommand(api, launchTickets) {
	// openclaw-local: Telegram Mini App dashboard command disabled
}
```

原注册语句 `api.registerCommand(createTelegramMiniAppDashboardCommand(api, launchTickets));`
被替换为注释，**函数体清空**。

**② 隐藏 native 命令** —— `commands-registry.data-*.mjs`

```js
// openclaw-local: dashboard native command hidden; text interceptor retained
defineBuiltinCommand("dashboard", "Disabled; use /status or /tasks.", "tools", "standard", { nativeName: false, args: [...] }),
```

`nativeName: false` 让它不再出现在命令菜单；保留 descriptor 是为了让手动输入的
`/dashboard` 仍能被解析器识别，从而走确定性分支（否则会被当成普通文本送进模型）。

**③ 放行确定性 fast path** —— `get-reply-*.mjs`

```js
return Boolean(commandName && commandName !== "new" && commandName !== "reset" &&
  /* openclaw-local: dashboard uses deterministic text fast path */ (isNativeCommandTurn(commandTurn) || ...));
```

原先是 `commandName !== "dashboard"`（即排除在 fast path 之外），改为放行。

**④ 替换原执行体** —— `commands-handlers.runtime-*.mjs`

```js
}, async () => {
	// openclaw-local: dashboard chat command disabled (no LLM/skill run)
	return commandReply("/dashboard 已停用。请使用 /status 查看状态,或使用 /tasks 查看后台任务。");
});
/* original dashboard handler retained below but unreachable for upgrade diff:
async function disabledDashboardHandlerOriginal(params, requirements) {
	...
}
*/
```

原执行体被 `/* */` 注释保留，便于上游升级时做 diff 比对。

### 保留了什么

删除的只是**聊天入口**。以下能力**不受影响**：

- 底层 OpenClaw Control UI
- browser 能力
- `control-ui` Skill
- `/status` 与 `/tasks` 原生命令（本来就是上游内置，未做任何修改）

---

## 上游升级时的注意事项

这些脚本依赖**文件名 glob** 与**源码字符串精确匹配**。升级镜像前必须确认：

| 依赖项 | 当前形态 | 升级后需核对 |
|---|---|---|
| registry 模块 | `commands-registry.data-*.mjs` | 文件名模式是否变化 |
| handler 模块 | `commands-handlers.runtime-*.mjs` | 同上 |
| miniapp 模块 | `miniapp-api-*.mjs` | 同上 |
| reply 模块 | `get-reply-*.mjs` | 同上 |
| registry 原行 | `defineBuiltinCommand("dashboard", "Create or update this session's dashboard.", ...)` | 描述文案或参数是否变化 |
| fast path 原行 | `commandName !== "new" && commandName !== "reset" && commandName !== "dashboard" &&` | 表达式是否变化 |
| handler 起止片段 | `const handleDashboardCommand = defineAuthorizedTextCommand({...` / `//#region src/auto-reply/reply/command-exec-result.ts` | 结构是否变化 |

**核对方法**：每个候选模块的数量断言必须为 1：

```python
if len(registry_candidates) != 1 or len(handler_candidates) != 1 \
   or len(miniapp_candidates) != 1 or len(reply_candidates) != 1:
    raise SystemExit(f'[disable-dashboard] unexpected module count: ...')
```

匹配失败会打印 `refusing blind patch` 并返回非 0，`entrypoint.sh` 随即拒绝启动。
此时应**先更新本目录脚本以适配新版本**，而不是绕过检查。

### 验证删除是否真的生效

不要只看脚本返回 0。应直接在容器内确认四个标记都存在：

```bash
docker exec openclaw-gateway ls /app/dist | grep -E '^commands-|^miniapp-|^get-reply-'
# 然后逐个 grep 下述标记：
#   dashboard chat command disabled            -> commands-handlers.runtime-*.mjs
#   dashboard native command hidden            -> commands-registry.data-*.mjs
#   dashboard uses deterministic text fast path-> get-reply-*.mjs
#   Telegram Mini App dashboard command disabled -> miniapp-api-*.mjs
```

四个标记齐全才说明四处修改全部落地。

---

## 历史教训

- **不要用「匹配失败就跳过」的宽松策略**处理控制面改动。不确定的行为比明确的失败更贵。
- **不要只看脚本输出的成功信息**。上游生产系统曾出现过日志打印 `backup ok` 而实际未备份关键文件的情况；
  本文档要求的所有验证都以**被改动对象的实际内容**为准，而不是脚本的自述。
