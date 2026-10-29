# Guardrail workflow evidence

Actual CLI verification rendered in a local browser capture. Temporary Git fixtures; no live accounts, messages, paid requests, or app state. Videos use captured browser frames with edited idle timing. They demonstrate checker/test execution, not a native app UI or hosted GitHub execution.

- PR 1: `6c186c708ca9cd695106b50cd017a8fffe327159` — Approved plans and short instructions
- PR 2: `2309a1da55c57e838bd2aa24cdd29c94a5a9b868` — PR size, scope, and review exceptions
- PR 3: `725f9df17db499807337e19f248b776482fe274e` — Swift complexity ratchet
- PR 4: `378d301b18832002806718691a39e1912e370ab5` — Instruction and tool-output budgets

The documentation-only capture prints the shortened instructions and preserved runbook size. The test captures exercise accepted and rejected inputs through the actual checkers; a passing test may assert an expected checker rejection.

Studio validation is unavailable: the configured isolated guest did not connect to its controller after start/reconnect attempts. These captures and tests are local fixture evidence, not Studio evidence.
