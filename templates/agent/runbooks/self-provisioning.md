# Runbook：自给自足（缺工具自己装，不要等人喂）

> 从 AGENTS.md 下沉（2026-09-16）。**需要装 Python 包或系统命令时读这个文件。**
> 铁律：**不存在「工具不存在」这个放弃理由——工具不存在 = 你还没装。**

---

## 1. 沙箱事实（先记住，别再试错浪费时间）

- 根文件系统**只读**（`/usr`、`/home/node` 都写不了），**没有 sudo**
  → `apt-get install` / `apt install` **必然失败**（`Read-only file system`），**不要试第二次**。
- **可写目录只有两个**：`/tmp`（临时，容器重建即丢）和 **`/opt/tools`（持久，跨会话保留）**。
- 环境变量已配好：`PYTHONPATH=/opt/tools`，`PATH` 含 `/opt/tools/bin`。
  装到 `/opt/tools` 的包**直接可 import**，可执行文件**直接可用**。
- 网络：**PyPI / 境外站点均可达**（沙箱共享 gateway 出口，不用配代理）。

---

## 2. Python 包缺失时（不许改需求、不许降级交付）

1. 确认真没有：`python3 -c "import X"`。
2. 若 `python3 -m pip` 不可用（首次才需要）：
   ```bash
   curl -sS --max-time 60 https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
   python3 /tmp/get-pip.py --target=/opt/tools --no-warn-script-location
   ```
3. 装包：
   ```bash
   python3 -m pip install --target=/opt/tools --no-cache-dir <pkg>
   ```
4. 验证：`python3 -c "import X; print(X.__file__)"`，确认路径在 `/opt/tools` 下。
5. 装完**写进 `memory/TECH-NOTES.md`**，下次直接用，别重复装。

---

## 3. 系统命令缺失时（如 pdftotext / pdfinfo / pdffonts）

- 不能 apt → 找**纯 Python 等价物**：
  - `pypdf` / `pdfminer.six` 代替 `pdftotext`
  - `Pillow` 处理图片
  - `pdfplumber` 抽表格
  自己 pip 装（流程同上）。
- 确实无解才报阻塞，且必须说明：**试过什么、为什么不行、需要什么权限**。

---

## 4. 报告阻塞时的最低要求

只试过一次现成方案就说「不行」= 违规。报阻塞前必须交代：
1. 试过哪几种方法（列出命令）
2. 每种为什么不行（贴原始错误）
3. 需要什么权限/凭据才能继续

**禁止**把「我没充分尝试」写成「环境不支持」。
