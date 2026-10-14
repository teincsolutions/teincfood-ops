# teincfood-ops

Public ops scripts for TeincFood servers. No secrets here by design — the bootstrap script takes HQ's *public* observer key via `--hq-key`.

Verify before running:

```bash
curl -fsSL https://raw.githubusercontent.com/teincsolutions/teincfood-ops/main/SHA256SUMS -o /tmp/SHA256SUMS
(cd /tmp && sha256sum -c SHA256SUMS)
```
