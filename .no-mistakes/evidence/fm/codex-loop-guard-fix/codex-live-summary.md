# Live Codex Stop-hook runs (codex-cli 0.160.0, real login, disposable lab FM_HOME + lab CODEX_HOME)
Lab primary = plain git checkout with AGENTS.md, bin/ from the commit under test, and the tracked .codex/hooks.json Stop hook.
Lab state has task1.meta (supervision needed) and no watcher, so every stop is "unhealthy".
Each agent reply after the first = one stop the guard blocked in the SAME Codex turn.

| run | guard | budget | window | agent replies | blocks in turn | jsonl |
|---|---|---|---|---|---|---|
| no progress | base 65e2aa44 | 2 | - | 2 | 1 (stop_hook_active=true waved through) | codex-live-base-guard.jsonl |
| no progress | HEAD 04c594b3 | 2 | 120 | 3 | 2 then budget release | codex-live-new-guard.jsonl |
| beacon touched after blocks 1,2 | HEAD | 1 | 120 | 4 | 3 then release on no-progress retry | codex-live-progress.jsonl |
| sleep 15s after block 1 | HEAD | 1 | 8 | 3 | 2 then release on immediate retry | codex-live-retry-window.jsonl |

Final ledger of the HEAD no-progress run (real Codex session_id/turn_id):
```
session=01a0fced-85cf-7f63-937f-fa2710fa7690
turn=01a0fced-88bb-7fa0-a25e-d50d2298a3f3
time=1790949830
beacon=missing
count=2
```
