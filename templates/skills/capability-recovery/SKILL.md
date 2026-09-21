---
name: capability-recovery
description: Use when a tool, Skill, command, API, dependency, sandbox, provider, or agent capability fails or is reported unavailable. Diagnose the actual runtime first, apply the smallest reversible repair, then perform a real end-to-end verification. Main may repair approved Gateway/runtime dependencies; guest may repair only its own workspace or sandbox and must hand off host-level work.
metadata: {"openclaw":{"requires":{"bins":[]}}}
---

# Capability Recovery

目标不是解释“为什么失败”,而是完成:诊断 → 最小修复 → 重载 → 验收 → 记录回滚。

## Mandatory workflow

1. **Freeze the symptom**:记录准确命令、实际运行环境、错误类别和复现结果。同一失败动作最多重复两次。
2. **Inspect the real runtime**:检查 `command -v`、版本、环境变量是否存在(绝不打印值)、Skill eligibility、sandbox/container 身份、网络路径和相关日志。不能只检查宿主状态。

   对已登记的依赖,优先执行确定性 helper:`capability-recover inspect <name>`;不要自行发明下载/复制路径。
3. **Classify**:
   - 缺少 binary/package:读取 `runbooks/self-provisioning.md`;
   - 配置错误:先做时间戳备份,一次只改一个变量,重载后验证;
   - 网络/provider 故障:读取 `research-recovery`,不要轮换仍有效的凭据;
   - 权限边界:不绕过,给出允许的转交路径;
   - Gateway 自身控制:不能从 Gateway 内 stop/rm/restart 当前 Gateway,交给宿主控制面。
4. **Repair minimally**:保留现有凭据、挂载、模型路由、SSH、Docker socket 和 guest 边界。优先用户目录/workspace 安装;main 的共享运行时依赖才走批准的宿主 provisioning 路径。

   若依赖已登记且 helper 可见,执行 `capability-recover restore <name>`,读取其 JSON 结果;只有 `ok=true` 且 `verified=true` 才能继续验收。
5. **Reload only what is required**:需要重建容器或 Gateway 时,先说明影响并保留回滚副本。
6. **Verify from the actual consumer**:重新执行 Skill check,并执行该能力的真实只读操作。“binary 存在”不等于成功。
7. **Close the loop**:报告修改路径、备份/回滚路径、验证证据和仍需用户/外部动作。确认结果后再将简短教训写入 self-improving。

## New capability workflow

当新任务需要一个目录中没有的工具时:

1. 在实际消费者中确认命令缺失、版本需求、运行位置和替代方案;
2. 优先使用用户态安装方式,不改宿主系统;
3. 完成一次真实只读验收后,用 `capability-catalog propose` 生成候选登记,不直接修改批准目录;
4. 候选登记必须包含 source、dest、verify 和 expected output;
5. 由 main/owner 审核后加入 `capability-catalog.json`,再由巡检自动守护;
6. 未登记能力不得由 Cron 自动下载或执行任意安装脚本。

示例:

```bash
capability-catalog propose <name> \
  --source /workspace/.capability-sources/<name> \
  --dest /opt/tools/bin/<name> \
  --verify-arg=--version \
  --contains '<已验证版本字符串>'
```

## Safety limits

- 通用恢复不执行 push、Issue/PR 写操作、公开发布、凭据轮换、删除、SSH/防火墙修改或破坏性容器操作。
- 不得把人工或另一个控制面完成的修改说成 agent 自己完成。
- 安装被阻塞时,保存诊断错误并切换兼容兜底(例如 GitHub 使用 `curl` REST API),禁止无限循环。

## Main / guest boundary

- Main 可以修复已批准的 Gateway/runtime 依赖,但仍须备份、最小变更、回滚和端到端验收。
- Guest 只能修改自己的 workspace、用户目录和 sandbox 依赖;宿主级依赖、Compose、systemd、Docker socket、Gateway、SSH、防火墙必须精确转交 main/owner。
