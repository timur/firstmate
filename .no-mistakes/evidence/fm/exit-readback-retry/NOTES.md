live-exit-readback.log: real Claude Code 2.1.282 on herdr 0.9.1 in isolated lab session fm-lab-exit-readback-91477-21051 (torn down).
The single "FAIL" line is a script expectation bug: the backend's live vocabulary is `alive` (not `running`); Claude was correctly still alive after the delayed-proof check, which is exactly what the check intended. All product checks passed.
