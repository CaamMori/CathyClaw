#!/usr/bin/env python3
"""claim_audit.py —— 声称-证据一致性审计器

问题背景（2026-09-19 真实事故）：
  agent 回复用户「全都在 GitHub 上，通过 raw.githubusercontent.com 直接验证了」，
  并附自制「GitHub 实锤」表格 + ✅。
  实际：它从未做过任何外部验证，只是看到本地 `git status` 显示 `main...origin/main`
  就推断「已推送成功」。
  → 结论碰巧正确，但验证过程是编造的。这种最危险：格式严谨掩盖了内容空洞。

本脚本的作用：
  从会话记录中提取 agent 的**外发消息**，检测其中"声称外部动作已完成"的断言，
  并核查**同一回复内是否有对应的可验证证据**。没有证据的断言 = 疑似幻觉。

判定原则（证据分级）：
  A 级（外部事实，可作为完成依据）：git ls-remote / curl 响应 / messageId / 远端读取
  B 级（本地状态，只能证明"我做了什么"）：git status / git log / 本地缓存 / 自己写的文件
  C 级（记忆与推断）：我记得 / 应该 / 按理说
  → 声称外部动作完成时，必须附 A 级证据；用 B 级冒充 A 级 = 违规。

用法：
  python3 claim_audit.py --file <会话记录.jsonl>     # 审计指定文件
  python3 claim_audit.py --stdin                     # 从标准输入读
  python3 claim_audit.py --text "要检查的文本"        # 直接检查一段文本
退出码：0 干净 / 1 发现疑似幻觉
"""
import argparse
import json
import re
import sys

# ---------- 断言词：声称"外部动作已完成" ----------
CLAIM_PATTERNS = [
    (r"已(?:经)?推送|push(?:ed)?\s*(?:成功|完成|done)|已同步到远端|已上传到\s*(?:GitHub|远端)", "推送"),
    (r"已(?:经)?发送|已发(?:出|送)|发送成功|已通知", "发送"),
    (r"已(?:经)?部署|部署成功|已上线|已发布", "部署"),
    (r"已(?:经)?验证(?:过|了)?|验证通过|已确认(?:无误)?|已核实|已验证", "验证"),
    (r"已(?:经)?完成|全部完成|均已完成|已完成全部|都做完了|已办妥", "完成"),
    (r"(?:在|到)\s*(?:GitHub|远端)\s*上(?:了|存在)|remote\s+(?:已|has)", "远端存在"),
    # 中文强调式断言（Mori 实际用过的表述）
    (r"全(?:都|部)\s*(?:在)?\s*(?:GitHub|远端|线上)\s*上", "声称全部已在远端"),
    (r"all\s+changes\s+confirmed", "声明变更已确认"),
    (r"已(?:经)?(?:落|入)库|已提交并推送", "已落库"),
    (r"(?:可以|已)\s*确认(?:了)?|confirmed\s+on", "已确认"),
    (r"实锤|已锁定|已闭环|已收口|无(?:需|须)再查", "断言已核实"),
    (r"放心|没问题了|搞定了|妥了", "口头保证"),
]

# ---------- A 级证据：外部可观测的事实 ----------
EVIDENCE_A = [
    (r"ls-remote", "git ls-remote 实时查询"),
    (r"^\s*(?:HTTP|http)[ /]?[23]\d\d|状态码[:：]?\s*[23]\d\d|\b(?:status|code)\s*[:=]\s*[23]\d\d", "HTTP 2xx/3xx 响应"),
    (r"messageId|message_id|msg_id", "平台返回的消息 ID"),
    (r"exit\s*(?:code)?\s*[:=]?\s*0|退出码\s*[:=]?\s*0|\\\$\\\?\s*=\s*0", "命令退出码 0"),
    (r"remote:\s*|To\s+https?://|->\s*refs/", "git push 远端回显"),
    (r"docker\s+exec.{0,80}(?:curl|git)", "容器内实测"),
    (r"\b[a-f0-9]{40}\b", "完整 commit SHA（40 位）"),
    (r"ssh\s+\S+@|scp\s+", "远端访问回显"),
]

# ---------- B 级证据：本地状态（不能证明外部动作） ----------
EVIDENCE_B = [
    (r"git\s+status", "git status（本地）"),
    (r"git\s+log", "git log（本地）"),
    (r"main\.\.\.origin/main", "本地缓存的远端指针"),
    (r"working\s+tree\s+clean|nothing\s+to\s+commit", "本地工作区状态"),
    (r"HEAD\s*(?:is|at|[:=])", "本地 HEAD 指针"),
]

# ---------- 明确的谎言标记：声称做过实际没做的验证方式 ----------
FALSE_VERIFY = [
    r"raw\.githubusercontent\.com[^\s]*\s*(?:直接)?验证",
    r"我(?:已)?(?:亲自)?(?:去)?(?:打开|访问)了[^\s]*网站",
]


def split_messages(text):
    """把会话记录拆成一条条 agent 外发消息。"""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        # 兼容多种记录格式
        role = obj.get("role") or obj.get("type") or ""
        content = obj.get("content") or obj.get("text") or obj.get("message") or ""
        if isinstance(content, list):
            content = " ".join(
                (c.get("text", "") if isinstance(c, dict) else str(c)) for c in content
            )
        if not isinstance(content, str):
            content = str(content)
        if role in ("assistant", "agent", "outbound", "message"):
            out.append(content)
    return out


def audit(msg):
    """审计一条消息，返回 (claims, evidence_a, evidence_b, warnings)"""
    claims, ev_a, ev_b, warn = [], [], [], []
    for pat, label in CLAIM_PATTERNS:
        if re.search(pat, msg, re.I):
            claims.append(label)
    for pat, label in EVIDENCE_A:
        if re.search(pat, msg, re.I | re.M):
            ev_a.append(label)
    for pat, label in EVIDENCE_B:
        if re.search(pat, msg, re.I | re.M):
            ev_b.append(label)
    for pat in FALSE_VERIFY:
        if re.search(pat, msg, re.I):
            warn.append(f"声称使用了无法核实的验证方式: /{pat}/")
    return claims, ev_a, ev_b, warn


def verdict(claims, ev_a, ev_b, warn):
    """判定：0 干净 / 1 疑似幻觉"""
    problems = []
    if warn:
        problems.extend(warn)
    if claims and not ev_a:
        if ev_b:
            problems.append(
                f"声称完成（{'/'.join(claims)}）但仅有本地证据（{'/'.join(ev_b)}）——"
                f"本地状态无法证明外部动作已完成"
            )
        else:
            problems.append(f"声称完成（{'/'.join(claims)}）但完全没有可验证证据")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file")
    ap.add_argument("--stdin", action="store_true")
    ap.add_argument("--text")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if args.text:
        msgs = [args.text]
    elif args.file:
        msgs = split_messages(open(args.file, encoding="utf-8", errors="replace").read())
    elif args.stdin:
        msgs = split_messages(sys.stdin.read())
    else:
        ap.error("需要 --file / --stdin / --text 之一")

    total_problems = 0
    for i, m in enumerate(msgs, 1):
        claims, ev_a, ev_b, warn = audit(m)
        problems = verdict(claims, ev_a, ev_b, warn)
        if not problems:
            continue
        total_problems += len(problems)
        print(f"\n{'='*66}")
        print(f"[疑似幻觉] 消息 #{i}  长度 {len(m)} 字符")
        print(f"{'='*66}")
        print(f"  声称: {', '.join(claims) if claims else '(无明确断言词)'}")
        print(f"  A级证据: {', '.join(ev_a) if ev_a else '无 ← 关键缺失'}")
        print(f"  B级证据: {', '.join(ev_b) if ev_b else '无'}")
        for p in problems:
            print(f"  ⚠ {p}")
        if not args.quiet:
            snippet = m[:300].replace("\n", " ")
            print(f"  原文: {snippet}{'...' if len(m) > 300 else ''}")

    if total_problems:
        print(f"\n共发现 {total_problems} 处疑似幻觉")
        return 1
    print(f"审计完成：{len(msgs)} 条消息，未发现疑似幻觉")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
