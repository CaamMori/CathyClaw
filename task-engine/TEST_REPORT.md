# Task Engine Test Report

## Final result

- Date: 2026-09-12 UTC
- Full-suite command: `python3 tests/test_engine.py -v`
- Result: **14 passed, 0 failed, 0 errors, 0 skipped**
- Reported unittest duration: **13.975 seconds**
- Process exit code: **0**
- Syntax checks: `python3 -m py_compile taskctl.py tests/test_engine.py` passed.

## Targeted coverage added

- A second verification is rejected while the first verification holds the task's exclusive nonblocking `run.lock`.
- Sequential and concurrent creates using the same task ID cannot overwrite the winning task.
- Task directories are mode `0700`; `task.json`, `run.log`, `verify.log`, and `run.lock` are mode `0600`.
- A symlink used as a task directory is rejected by create/status and omitted by list.
- `NaN`, positive/negative infinity, zero, and negative timeouts are rejected without changing task state.
- Status checks during worker launch do not incorrectly mark the task orphaned.
- Timeout cleanup follows a worker-owned `start_new_session` process group after its leader exits, then kills a descendant that ignores `SIGTERM`; the test verifies the descendant is absent or terminated (zombie), never alive.

## Repetition for race-sensitive scenarios

The following three tests were run together **3 consecutive times** (9 test executions total), all passing:

- timeout cleanup of a SIGTERM-ignoring descendant after leader exit
- concurrent verification lock rejection
- concurrent same-ID create protection

Per-run results: **3/3 passed**, **3/3 passed**, **3/3 passed**.

## Limitations

- Process ownership validation intentionally relies on Linux `/proc`, consistent with the existing PID validation implementation; this cleanup implementation is not portable to systems without `/proc`.
- A killed descendant may remain briefly as a zombie until adopted/reaped; tests accept only absent or zombie state, never a live process.
- `pytest` is not installed in this environment; the project uses and was fully exercised through Python standard-library `unittest`.
- All tests used isolated temporary task roots and harmless subprocesses; no infrastructure, network, Docker, credentials, or global configuration were touched.

## 第二階段主代理回歸（取代前次測試數量）
目前完整代碼：23項測試全部通過，25.499秒。含子任務後續落盤案例與主代理新增3項真實產物接手測試。不同套件存在語義重疊，不等於23類獨立風險。
命令：`python3 -m unittest discover -s tests -v`；原始日誌 regression-handoff.log。
新增驗收：跨CLI生成/內容與SHA256驗收/不重跑；損壞文件拒絕並明確修復重驗；文件缺失拒絕。
範圍僅本地進程，未做真實/new或容器重啟測試。
