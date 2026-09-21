#!/bin/sh
# gen-env-snapshot.sh — bot 环境快照生成器（/data/state/workspace/memory/ENV-SNAPSHOT.md）
# cron: 30 4 * * * root /usr/local/bin/gen-env-snapshot.sh
# 设计：原子写（tmp+mv），失败非零退出不落半截文件；纯只读采集，无状态变更、无循环 docker exec
# bot 侧认知：见 workspace/AGENTS.md「环境与部署认知」节
set -u
OUT="/data/state/workspace/memory/ENV-SNAPSHOT.md"
TMP="${OUT}.tmp.$$"
trap 'rm -f "$TMP"' EXIT

now=$(date '+%Y-%m-%d %H:%M %Z')
up=$(uptime -p 2>/dev/null | sed 's/^up //')
load=$(cut -d' ' -f1-3 /proc/loadavg)
cores=$(nproc)
memline=$(free -h | awk '/^Mem:/{printf "%s 总量 / %s 已用 / %s 可用", $2, $3, $7}')
swapline=$(free -h | awk '/^Swap:/{if ($2=="0" || $2=="0B") print "无"; else printf "%s 总量 / %s 已用", $2, $3}')
diskline=$(df -h / | awk 'NR==2{printf "%s 总量 / %s 已用 (%s) / %s 剩余", $2, $3, $5, $4}')
# 公网 IP 是云平台 DNAT 映射，网卡上不存在（换机/换云时人工更新此值）
PUB_IP="160.202.238.171"
nicip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet/{print $2}' | cut -d/ -f1 | tr '\n' ' ' | sed 's/ $//')

ver=$(docker exec openclaw-gateway openclaw --version 2>/dev/null | head -1)
[ -z "$ver" ] && ver="(采集失败,容器可能重启中)"

sk=$(docker exec openclaw-gateway sh -c 'openclaw skills check 2>/dev/null | grep -c "Ready and visible"') || sk="采集失败"

rows=$(docker ps --format '{{.Names}}|{{.Status}}' | awk -F'|' '{printf "| %s | %s |\n", $1, $2}')
[ -z "$rows" ] && rows="| (docker ps 无输出) | 严重异常 |"

cat > "$TMP" <<EOF
# ENV-SNAPSHOT — 本机环境实时快照

> 本文件由宿主脚本 gen-env-snapshot.sh **每日 04:30 自动生成并覆盖**。
> **不要手工编辑**（改了也会被下次刷新覆盖）。发现数据与实际不符：写进你自己的 memory/ 笔记并向所有者报告。
> 生成时间：${now}
> **新鲜度判断**：上行时间戳距今超过 48 小时 = 数据可能过期，回答资源类问题时主动说明。

## 宿主机资源（实测）

| 项 | 值 |
|---|---|
| 公网 IP（云 DNAT 映射，网卡上没有） | ${PUB_IP} |
| 本机网卡 IP（实测） | ${nicip} |
| CPU | ${cores} 核 |
| 内存 | ${memline} |
| Swap | ${swapline} |
| 磁盘 / | ${diskline} |
| 开机时长 | ${up} |
| 负载 (1/5/15min) | ${load} |

## OpenClaw 部署

- 版本：${ver}
- skills ready 数：${sk}
- memory 检索：local embedding（managed llama.cpp，按需启停，零 API 费用）

## 容器清单（docker ps 实测）

| 容器 | 状态 |
|---|---|
${rows}

## 你看不到的东西（诚实边界，别猜）

- 宿主 cron 矩阵（/etc/cron.d/openclaw-ops 共 10 项）、守护脚本（/usr/local/bin/）、mihomo 配置——都在宿主/gateway 侧，你的沙箱没有 docker CLI，看不见；当前职责清单见 SELF.md 第 3 节。
- 实时健康：selfcheck 15 项巡检（每 10 分钟快检）+ ocwatch TG 告警就是你的健康信息源——**没有告警 = 一切正常**，不需要你主动探测宿主。
- 容器内 /proc/meminfo、df 因无资源隔离恰好等于宿主值，但这是巧合不是契约，资源问答以本快照为准。
EOF

chown 1000:1000 "$TMP" 2>/dev/null
chmod 644 "$TMP"
mv -f "$TMP" "$OUT" || exit 1
trap - EXIT
exit 0
