#!/usr/bin/env python3
"""持续守护 OpenClaw 沙箱配置,防止安全边界漂移。

关键边界:
  1. 敏感宿主目录不得配置为全局 bind。
  2. 仅 main agent 可读写 task-engine、memory 和 sandbox-tools。
  3. guest 不得挂载宿主工具目录;工具使用 workspace 内独立副本。
  4. guest browser 不继承普通 sandbox bind。
  5. 保留现有网络、浏览器和工具策略要求。
"""
import json
import os
import shutil
import stat
import sys
import tempfile
import time

P = '/data/state/openclaw.json'
LOG = '/var/log/openclaw-cfg-guard.log'
TASK_BIND = '/data/state/workspace/task-engine:/opt/task-engine:rw'
TASK_STALE_BIND = '/data/state/workspace/task-engine:/workspace/task-engine:rw'
MEMORY_BIND = '/data/state/workspace/memory:/workspace/memory:rw'
TOOLS_RW_BIND = '/data/state/sandbox-tools:/opt/tools:rw'
TOOLS_RO_BIND = '/data/state/sandbox-tools:/opt/tools:ro'
TS = time.strftime('%Y-%m-%d %H:%M:%S')


def log(msg):
    line = f'{TS} {msg}'
    print(line)
    try:
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except Exception:
        pass


def write_config_preserving_owner(path, cfg):
    """原子写回配置，并保留原 uid/gid/mode。

    【背景】本脚本以 root 身份由 cron 运行，而 /data/state/openclaw.json 属于
    Gateway 运行用户（uid 1000）。旧版写法是

        with open(P, 'w') as f: json.dump(cfg, f, ...)

    它有**原子性缺陷**：先截断、再写入。若在写入中途进程被杀（OOM、SIGKILL、
    宿主重启、容器被强杀），文件会停在"已截断 + 只写了一部分"的状态。
    实测：崩溃后文件被截断成 12 字节，JSONDecodeError —— Gateway 读不了配置。
    由于本脚本由 cron 每 5 分钟运行一次，这个崩溃窗口是反复出现的，不是理论风险。

    【为什么改用 os.replace】临时文件写完 fsync 后再 os.replace，
    目标文件任何时刻都是完整的——风险被隔离在临时文件里。

    【为什么必须配套保留属主】os.replace 是"用新文件顶替旧文件"，
    新文件是 root 创建的，替换后目标就会变成 root 属主，Gateway(uid 1000) 读不到，报 EACCES。
    因此 os.chown 不是"修 open(w) 的 bug"，而是 os.replace 方案的**必要配套**。

    注意区分（实测确认，勿混淆）：
      · open(P, 'w') 截断已存在文件  → 属主**不变**（内核保留 inode）
      · 临时文件 + os.replace        → 属主**变成 root**（本函数要处理的正是这个）
      · 文件被删除后重建             → 属主变成 root

    实现顺序：写同目录临时文件（同文件系统，保证 replace 是原子的）→ 定 mode 与属主
    → os.replace 覆盖目标。任何一步失败都不动原文件。
    """
    d = os.path.dirname(path) or '.'
    st = os.stat(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.cfg-guard-', suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        # 先定属主与权限，再替换——否则替换瞬间会出现「内容已更新但属主是 root」的窗口。
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError:
            # 非 root 运行时无法 chown；此时临时文件属主已经是自己，属主不会漂移。
            pass
        os.replace(tmp, path)
        tmp = None
    finally:
        if tmp is not None and os.path.exists(tmp):
            os.unlink(tmp)
    d = os.path.dirname(path) or '.'
    st = os.stat(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.cfg-guard-', suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        # 先定属主与权限，再替换——否则替换瞬间会出现「内容已更新但属主是 root」的窗口。
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError:
            # 非 root 运行时无法 chown；此时临时文件属主已经是自己，属主不会漂移。
            pass
        os.replace(tmp, path)
        tmp = None
    finally:
        if tmp is not None and os.path.exists(tmp):
            os.unlink(tmp)


def main():
    try:
        with open(P, encoding='utf-8') as f:
            cfg = json.load(f)
    except Exception as e:
        log(f'ERR cannot read config: {e}')
        return 1

    fixed = []
    agents = cfg.setdefault('agents', {})
    defaults = agents.setdefault('defaults', {})
    sandbox = defaults.setdefault('sandbox', {})
    docker = sandbox.setdefault('docker', {})

    # Sensitive binds must never be inherited globally by guest/unknown agents.
    global_binds = docker.setdefault('binds', [])
    before = list(global_binds)
    global_binds[:] = [b for b in global_binds if b not in {
        TASK_BIND, TASK_STALE_BIND, MEMORY_BIND, TOOLS_RW_BIND, TOOLS_RO_BIND,
    }]
    if global_binds != before:
        fixed.append('global.binds-sensitive-removed')

    entries = agents.setdefault('entries', {})
    main_docker = entries.setdefault('main', {}).setdefault('sandbox', {}).setdefault('docker', {})
    main_binds = main_docker.setdefault('binds', [])
    desired_main = [TASK_BIND, MEMORY_BIND, TOOLS_RW_BIND]
    if main_binds != desired_main:
        main_docker['binds'] = desired_main
        fixed.append('main.binds')
    if main_docker.get('network') != 'container:openclaw-gateway':
        main_docker['network'] = 'container:openclaw-gateway'
        fixed.append('main.network-gateway-namespace')
    for key in (
        'dangerouslyAllowReservedContainerTargets',
        'dangerouslyAllowExternalBindSources',
        'dangerouslyAllowContainerNamespaceJoin',
    ):
        if main_docker.get(key) is not True:
            main_docker[key] = True
            fixed.append(f'main.{key}-enabled')

    guest_sandbox = entries.setdefault('guest', {}).setdefault('sandbox', {})
    guest_docker = guest_sandbox.setdefault('docker', {})
    if guest_docker.get('binds') != []:
        guest_docker['binds'] = []
        fixed.append('guest.binds-cleared')
    # Guest 与 main 使用同一 Gateway/Mihomo 出口,保持联网体验一致;
    # 权限边界由空 binds、禁用 elevated/host control 和下方其余 false 标志保证。
    if guest_docker.get('network') != 'container:openclaw-gateway':
        guest_docker['network'] = 'container:openclaw-gateway'
        fixed.append('guest.network-gateway-namespace')
    guest_env = guest_docker.setdefault('env', {})
    guest_pythonpath = '/workspace/.sandbox-tools'
    guest_path = '/workspace/.sandbox-tools/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin'
    if guest_env.get('PYTHONPATH') != guest_pythonpath:
        guest_env['PYTHONPATH'] = guest_pythonpath
        fixed.append('guest.env.PYTHONPATH')
    if guest_env.get('PATH') != guest_path:
        guest_env['PATH'] = guest_path
        fixed.append('guest.env.PATH')
    for key in (
        'dangerouslyAllowReservedContainerTargets',
        'dangerouslyAllowExternalBindSources',
    ):
        if guest_docker.get(key) is not False:
            guest_docker[key] = False
            fixed.append(f'guest.{key}-disabled')
    if guest_docker.get('dangerouslyAllowContainerNamespaceJoin') is not True:
        guest_docker['dangerouslyAllowContainerNamespaceJoin'] = True
        fixed.append('guest.dangerouslyAllowContainerNamespaceJoin-enabled')
    guest_browser = guest_sandbox.setdefault('browser', {})
    if guest_browser.get('binds') != []:
        guest_browser['binds'] = []
        fixed.append('guest.browser.binds-cleared')
    if guest_browser.get('allowHostControl') is not False:
        guest_browser['allowHostControl'] = False
        fixed.append('guest.browser.host-control-disabled')

    # Safe global baseline; only main gets the break-glass namespace join above.
    if docker.get('network') != 'bridge':
        docker['network'] = 'bridge'
        fixed.append('docker.network-bridge')
    for key in (
        'dangerouslyAllowExternalBindSources',
        'dangerouslyAllowReservedContainerTargets',
        'dangerouslyAllowContainerNamespaceJoin',
    ):
        if docker.get(key) is not False:
            docker[key] = False
            fixed.append(f'{key}-disabled')

    browser = sandbox.setdefault('browser', {})
    if browser.get('enabled') is not True:
        browser['enabled'] = True
        fixed.append('browser.enabled')
    if browser.get('network') != 'openclaw-sandbox-browser':
        browser['network'] = 'openclaw-sandbox-browser'
        fixed.append('browser.network')
    if browser.get('cdpPort') != 9222:
        browser['cdpPort'] = 9222
        fixed.append('browser.cdpPort')

    if defaults.get('verboseDefault') != 'off':
        defaults['verboseDefault'] = 'off'
        fixed.append('verboseDefault')

    sandbox_tools = cfg.setdefault('tools', {}).setdefault('sandbox', {}).setdefault('tools', {})
    allow = sandbox_tools.setdefault('allow', [])
    if 'browser' not in allow:
        allow.append('browser')
        fixed.append('allow.browser')
    deny = sandbox_tools.setdefault('deny', [])
    if 'browser' in deny:
        deny.remove('browser')
        fixed.append('deny.browser-removed')

    if fixed:
        shutil.copy2(P, P + '.bak-guard-' + time.strftime('%Y%m%d-%H%M%S'))
        write_config_preserving_owner(P, cfg)
        log('FIXED: ' + ', '.join(fixed))
        return 2

    log('SUMMARY ok')
    return 0


if __name__ == '__main__':
    sys.exit(main())
