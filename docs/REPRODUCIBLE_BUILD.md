# Reproducible unsigned build

`NativeHostToolchain.lock.json` pins the exact Roslyn compiler, supporting
assemblies, .NET Framework 4.7.2 reference assemblies, byte sizes, versions,
and SHA-256 values. The builder fails closed if any locked file is absent or
different.

The current lock targets Visual Studio 18.5 Community at the default path. A
reviewer may pass another absolute `-ToolchainRoot`, but its files must still
match every lock entry exactly. The build never downloads a compiler and never
uses an unpinned `csc.exe` from `PATH`.

The official public release builder must run in **64-bit Windows PowerShell
5.1 Desktop**. It rejects PowerShell 7 (`pwsh.exe`) and 32-bit Windows
PowerShell before importing build modules or creating staging/output files.
This host restriction is part of the byte-for-byte archive contract: Windows
PowerShell 5.1 and PowerShell 7 format `ConvertTo-Json` output differently.
It does not change the Native Host runtime requirements.

Example:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\Build-UnsignedRelease.ps1 `
  -Version 0.1.0 `
  -OutputDirectory C:\review\taipower-ami-output
```

Run the command from a 64-bit process. On a 64-bit Windows installation, a
32-bit parent process may redirect `System32` to `SysWOW64`; such an invocation
is intentionally rejected.

The builder:

1. validates the toolchain lock and extension contract;
2. copies the C# source into two different absolute staging paths;
3. compiles both with `/deterministic+` and a stable `/pathmap`;
4. requires identical executable bytes and SHA-256 values;
5. rejects overwrite of existing release artifacts;
6. emits unsigned release metadata and `SHA256SUMS`; and
7. creates a sorted ZIP with fixed entry timestamps plus a sidecar SHA-256.

Run the complete local gate:

```powershell
.\tests\Test-PublicSafety.ps1
node.exe .\tests\test_extension.js
node.exe .\tests\test_transaction_order.js
.\tests\Test-NativeHostDestination.ps1
.\tests\Test-RegistryCas.ps1
.\tests\Test-TransactionStructure.ps1
.\tests\Test-SourceProvenance.ps1
.\tests\Test-BuildHostGate.ps1
.\tests\Test-PackageNeutrality.ps1
.\tests\Test-DeterministicBuild.ps1
```

Run the PowerShell test commands in 64-bit Windows PowerShell 5.1. The build
host test launches `pwsh.exe` when available and verifies that the unsupported
host fails before producing staging or release output; it reports that one
negative probe as skipped when PowerShell 7 is not installed.

`Test-PackageNeutrality.ps1` builds the exact 2.0.1 public package and scans
both its text and executable byte representations for private identity,
environment, signing, and credential material. It also verifies that release
metadata, the extension manifest, and the Native Host file version all carry
2.0.1.

`Test-NativeHostDestination.ps1` exercises the compiled Host in a short-lived
Windows PowerShell child process. It covers local volume roots, native UNC
share roots without network access, a real local directory identity, missing
parents, and a junction rejection. To add a live UNC handle-identity check,
set `TAIPOWER_AMI_TEST_UNC_PARENT` to an existing reviewed share directory;
otherwise that one network-dependent case is reported as skipped.

The source checkout may be dirty during development, but publication requires
`source_tree_state: clean`, an immutable source commit, identical results from
a second clean checkout, and the complete Hyper-V matrix. The private signer
must never be introduced into this repository or its CI secrets.
