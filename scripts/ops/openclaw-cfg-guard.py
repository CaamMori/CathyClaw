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

    【为什么必须这样做】本脚本以 root 身份由 cron 运行，而 /data/state/openclaw.json
    属于 Gateway 运行用户（uid 1000）。早期版本的写法是

        with open(P, 'w') as f: json.dump(cfg, f, ...)

    它是「先截断、再写入」，并且新建/重写后的文件属主会是 root。由此产生两个真实事故：

      1. 中途崩溃会留下被截断的半个 JSON，Gateway 直接读不了配置；
      2. 写完后属主变成 root，Gateway(uid 1000) 读不到，报 EACCES。

    第 2 点在上游生产机上真实发生过（见变更记录 §9.4「原子写配置造成 owner 短暂变化」），
    当时的处置是「之后的原子写入显式保留原 uid/gid/mode」——本函数即该处置的落地。

    实现：写同目录临时文件（同文件系统，保证 os.replace 是原子的）→ 恢复属主与 mode
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
