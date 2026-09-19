# cfg-guard 原子写：实测记录与一处结论修正

针对 `scripts/ops/openclaw-cfg-guard.py` 的写回方式，在真实机器上做了对照实验。
本文记录实测数据，并**修正上一提交（e3194e2）中一处错误的归因**。

---

## 一、修正：属主漂移的真正原因

上一提交的说明里我写了：

> 原实现 `open(P, 'w')` 先截断再写入，且写回后属主变成 root …… 直接导致 EACCES。

**这个归因是错的。** 实测数据：

| 写法 | 操作 | 结果属主 |
|---|---|---|
| `open(P, 'w')` | 截断**已存在**的文件 | **uid=1000 保留** ✅ |
| 临时文件 + `os.replace` | 原子替换 | **uid=0 漂移** ❌ |
| `open(P, 'w')` | 写到**不存在**的路径（重建） | **uid=0 漂移** ❌ |

原因是 `open(P, 'w')` 对已存在的文件只做**截断**，内核保留 inode，属主不变。
真正会改变属主的是"新建文件"这条路——也就是 `os.replace(临时文件, 目标)`，
因为临时文件是 root 创建的，替换后目标就继承了 root 属主。

**结论**：变更记录 §9.4 那次 EACCES 事故，真凶是"原子替换"（`os.replace`），
**不是** `open(w)`。生产机上那个版本的 cfg-guard 用的是 `open(w)`，
它不会引起属主漂移。

### 那么新版的 `os.replace` 为什么反而要保留属主？

因为新版**主动选择了 `os.replace`**（为了原子性，见下节）。
一旦用了这个写法，就**必须**配套恢复 `uid/gid/mode`，否则就会踩进上面第二行那个坑。
`write_config_preserving_owner()` 里的 `os.chown(tmp, st.st_uid, st.st_gid)`
正是为此存在的——它不是"修 `open(w)` 的 bug"，而是"`os.replace` 方案的配套必要条件"。

---

## 二、原子性：这才是真正的改进（有实测）

`open(P, 'w')` 的问题是**非原子**：它先截断、再写入。
如果在写入中途进程被杀（OOM、超时被 SIGKILL、宿主重启、容器被强杀），
文件会停留在"已截断 + 只写了一部分"的状态。

**崩溃注入实测**（在测试机 `44.200.155.154` 上执行）：

```
--- 旧版：open(w) 先截断 ---
  模拟崩溃：文件已被截断且只写了一半
  崩溃后文件大小: 12 字节
  崩溃后是否仍是合法 JSON: 否 -> JSONDecodeError

--- 新版：临时文件 + os.replace ---
  模拟崩溃：临时文件写了一半，但目标文件未被触碰
  目标文件是否仍是合法 JSON: 是（完好）
```

| 场景 | 旧版 | 新版 |
|---|---|---|
| 写入中途崩溃 | 配置被截断成 12 字节，**JSONDecodeError** | 目标文件**完好**，仍是合法 JSON |
| Gateway 后果 | 读不了配置，起不来 | 读到旧配置，正常运行 |

`/data/state/openclaw.json` 是 Gateway 的**唯一配置源**，且由 cron 每 5 分钟
自动改写一次。这意味着旧版的崩溃窗口**每 5 分钟出现一次**——不是理论风险。

原子写的价值就在这里：把风险隔离在临时文件里，目标文件**任何时刻都是完整的**。

---

## 三、保留属主的实测验证

`write_config_preserving_owner()` 在测试机上的验证：

```
测试前: /data/state/openclaw.json  ubuntu:ubuntu(1000:1000)  600
运行新版 cfg-guard → FIXED: <19 项修复，真实写入>
测试后: /data/state/openclaw.json  ubuntu:ubuntu(1000:1000)  600   ← 无漂移
```

19 项修复全部触发（说明确实走了写回路径），属主与权限均未变化。
另一项检查：写回后**无残留临时文件**（`/data/state/` 下 `.cfg-guard-*` 计数为 0）。

---

## 四、这两个问题的独立性

需要区分清楚，它们是两件事：

| 问题 | 旧版 | 新版 | 危害 |
|---|---|---|---|
| **原子性** | 有缺陷（截断式写入） | 已修（`os.replace`） | 崩溃后配置损坏，Gateway 起不来 |
| **属主保留** | 无此问题（`open(w)` 保留属主） | 必须显式处理（因为改用 `os.replace`） | 不处理则 uid 漂移 → EACCES |

新版是**用"必须配套保留属主"换取了"原子性"**。这个交换是划算的：
崩溃损坏配置是难以恢复的，而属主漂移只需要在写回时多调一次 `os.chown`。

---

## 五、相关脚本：`shutil.copy2` 的行为

旧版在写回前会做一份备份：

```python
shutil.copy2(P, P + '.bak-guard-' + timestamp)
```

`copy2` **保留 mode 与时间戳，但不保留属主**（`copy2` 只复制元数据，
不做 `chown`；只有 `copy2` 的调用方显式 `chown` 才行）。

因此生产机上看到的备份件属主是 `root:root`：

```
-rw------- 1 root root 20724 Sep 20 02:10 /data/state/openclaw.json.bak-guard-20260920-021406
```

这是**预期的**，不是缺陷——备份件由 root 生成、被 root 读取即可。
但要注意：**不能把备份件直接 `cp` 回原位**，那会把属主变成 root 并触发 EACCES。
正确的恢复方式是：

```bash
cp -a <备份件> /data/state/openclaw.json   # -a 保留属主，但源是 root 仍会带过去
chown 1000:1000 /data/state/openclaw.json  # 必须显式改回
chmod 600 /data/state/openclaw.json
```

上游文档的 §12 回滚指南里正是这么写的（`cp -a` 后接 `chown 1000:1000`），
那是**正确**的写法。

---

## 六、复现方法

在任意测试机（**不要在生产机**）上执行：

```bash
# 1. 原子性对照
cp /data/state/openclaw.json /tmp/orig.json
python3 -c 'f=open("/data/state/openclaw.json","w"); f.write("{\"partial\": "); f.flush()'
python3 -c 'import json; json.load(open("/data/state/openclaw.json"))'   # 预期 JSONDecodeError
cp /tmp/orig.json /data/state/openclaw.json

# 2. 属主对照
chown 1000:1000 /data/state/openclaw.json
python3 -c 'import json,os,tempfile; P="/data/state/openclaw.json"; d=os.path.dirname(P)
fd,t=tempfile.mkstemp(dir=d); os.close(fd)
open(t,"w").write(json.dumps(json.load(open(P))))
os.replace(t,P)'
stat -c '%u:%g' /data/state/openclaw.json   # 预期 0:0 —— 证明 os.replace 会漂移属主
```
