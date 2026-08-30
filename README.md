# Taipower AMI Windows Companion

Public release candidates must pass the [Windows VM validation gate](docs/VM_VALIDATION.md).

> Alpha architecture under private validation. Do not treat the current
> checkout as an approved production installer or signed release.

This repository contains the reusable Windows side of the Taipower AMI
read-only Home Assistant integration. The current neutral public identity is
version **2.0.1**:

- a fixed-ID Chrome extension;
- a Native Messaging host;
- a user-scoped LocalAppData installer and uninstaller; and
- deterministic unsigned release construction with SHA-256 provenance.

Built unsigned archives also carry an offline release README, the complete
installation procedure, the security policy, and the Apache License 2.0 text.
All four files are included in `SHA256SUMS`; the installer rejects a package
when they are missing or have changed.

The user signs in to the official Taipower website in a normal visible Chrome
window and completes any human verification personally. The project does not
store or fill the account password, automate CAPTCHA/Turnstile, use remote
debugging, or perform unattended login.

## Distribution boundary

This repository publishes unsigned source and, when explicitly released,
clearly labelled unsigned binaries. It never uses the private production
signer, changes WDAC policy, creates a certificate, installs a Windows service,
or automatically elevates at runtime.

Official unsigned archives are built only with **64-bit Windows PowerShell 5.1
Desktop**. The builder rejects PowerShell 7 (`pwsh.exe`) and 32-bit Windows
PowerShell before creating staging or output files because their JSON layout is
not part of the locked byte-for-byte archive format. This restriction applies
to release construction, not to normal Native Host execution.

The Home Assistant custom integration is maintained in the separate
[`taipower-ami-ha`](https://github.com/ctes-08/taipower-ami-ha) repository.
HACS installs only that integration; it cannot install this Windows Companion.

## Operator configuration

The public companion is installed without elevation for the current Chrome
user under `%LOCALAPPDATA%\TaipowerAMIV2`. It reads the handoff destination
from the 64-bit registry view at:

`HKCU\Software\TaipowerAMI` / `CredentialDestination` (`REG_SZ`)

The installer writes this value. It must be an absolute
local or native UNC path whose exact filename is `credentials.json`; mapped
network drives, environment expansion, device paths, an unavailable parent,
and reparse points anywhere in the existing destination ancestry are
rejected. Immediately before and during each handoff, the Native Host rereads
the Registry64 value, rejects reparse points, and compares the opened parent
directory's final handle identity. It fails closed when the setting changes,
is absent, or is invalid. Before creating a new handoff temporary file, it also
performs a bounded best-effort cleanup of only old, small, ordinary files that
match its exact private `.credentials.json.<32-lowercase-hex>.tmp` grammar; it
does not follow reparse points or touch recent/oversized/non-matching entries.

Because both LocalAppData and this HKCU value are controlled by the same
ordinary Windows user, these checks are fail-closed consistency and
defense-in-depth—not a privilege boundary against malware already executing
as that user.

See [Installation](docs/INSTALLATION.md) and
[Reproducible build](docs/REPRODUCIBLE_BUILD.md). Do not install an alpha
checkout on a production computer; complete the VM matrix first.

## Current publication gate

The first release remains blocked until all of the following pass:

- no household path or HA credential is compiled into the Native Host;
- the handoff destination is configured explicitly by the operator;
- the archive is produced by the required 64-bit Windows PowerShell 5.1 host;
- two clean builds from different staging paths produce the same EXE hash;
- installer, uninstaller, extension protocol, and secret-redaction tests pass;
- the exact unsigned archive and sidecar hash are reproducible; and
- a fresh Windows VM completes install, Chrome Native Messaging, uninstall,
  and reinstall tests.

The private GitHub staging repository also runs the complete source gate in a
clean hosted Windows checkout. That workflow downloads only pinned compiler
inputs, verifies their SHA-256 values and the Microsoft Authenticode identity
of the Visual Studio bootstrapper, then lets this repository's stricter
per-file toolchain lock fail closed. CI does not upload a release artifact and
does not replace the disposable-VM Chrome/Native Messaging matrix.

Before changing repository visibility, enable private vulnerability reporting,
run the workflow once, require its `windows-powershell-5.1` job in the default
branch ruleset (shown under `Public Windows gate` in the Actions UI), review the
issue privacy warning, and repeat the full-history secret scan from a fresh
clone.

## License

Copyright 2026 ctes-08 and contributors.

Licensed under the [Apache License 2.0](LICENSE). The license is also included
in every unsigned release archive and covered by its `SHA256SUMS`.
