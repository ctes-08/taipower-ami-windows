# Hyper-V test matrix

Run this matrix only after deterministic source validation. Use a disposable
patched Windows VM with a normal Chrome user. This repository's installer is
user-scoped and must never ask for administrator credentials. Do not place
production credentials or signing keys in the VM image.

| Scenario | Required result |
| --- | --- |
| Clean install | Declared paths only; fixed extension/host identities; correct absolute manifest and registration |
| Real Chrome call | Visible manual login; one bounded response; HA accepts schema v1; no secrets in evidence |
| Upgrade N to N+1 | New package fully validated before activation; a pre-commit failure restores the prior user-scoped components and HKCU values |
| Interrupted install | A pre-commit interruption leaves no trusted partial registration; rerun either completes or returns an actionable failure |
| Tampered package | A changed, added, or missing packaged file fails `SHA256SUMS` coverage before installation |
| Destination validation | Relative, mapped-drive, missing-parent, device, and reparse-ancestry destinations fail closed |
| Interrupted credential handoff | A stale exact-name temporary file is cleaned on a later handoff; recent, oversized, malformed-name, directory, and reparse candidates remain untouched |
| Uninstall, retain extension | Exact owned host registration/configuration removed; `credentials.json` and extension bundle retained |
| Uninstall, remove extension | Exact owned registration/configuration/components removed; `credentials.json` still retained |
| Reinstall | Clean recreation without stale state; real Native Messaging call succeeds |

Record Windows and Chrome versions, source commit, toolchain-lock hash, file
hashes, and sanitized pass/fail output. Scan all retained evidence for
sessions, AMI identifiers, tokens, account numbers, usernames, LAN addresses,
and UNC paths. Program Files, signed-release, physical Previous, and offline
production rollback testing belongs to the separate private channel and is
not evidence that this public installer implements those features.
