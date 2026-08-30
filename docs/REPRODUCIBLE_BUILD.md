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
6. copies the reviewed release README, installation procedure, privacy,
   security, and Code signing policies, and Apache License 2.0 terms into the
   package;
7. emits unsigned release metadata and a `SHA256SUMS` that covers those
   documents and every other packaged file; and
8. creates a sorted ZIP with fixed entry timestamps plus a sidecar SHA-256.

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
2.0.1. It requires byte-exact packaged copies of the release README,
installation procedure, privacy and security policies, Code signing policy,
and license, and confirms that `SHA256SUMS` covers them. The 2.0.1 gate
additionally pins the reviewed
private/public cross-channel unsigned Native Host SHA-256 so that
packaging-only differences cannot silently change the shared executable. The
pinned value is the 2.0.1 pre-signing executable, not the separate 2.0.0
rollback-lab fixture. A source or version change requires a new reviewed
compatibility hash rather than weakening this assertion.

`Test-NativeHostDestination.ps1` exercises the compiled Host in a short-lived
Windows PowerShell child process. It covers local volume roots, native UNC
share roots without network access, a real local directory identity, missing
parents, and a junction rejection. To add a live UNC handle-identity check,
set `TAIPOWER_AMI_TEST_UNC_PARENT` to an existing reviewed share directory;
otherwise that one network-dependent case is reported as skipped.

## Hosted CI boundary

`.github/workflows/validate.yml` runs the complete gate with 64-bit Windows
PowerShell 5.1. It does not trust the changing compiler preinstalled on
`windows-latest`. `tests/Prepare-CiToolchain.ps1` instead downloads a fixed
Visual Studio Build Tools bootstrapper and the fixed .NET Framework 4.7.2
reference-assembly package, verifies both SHA-256 values, verifies the
bootstrapper's Microsoft Authenticode signer, installs into an isolated path,
and finally invokes `PublicToolchain.psm1` to check every locked compiler and
reference file. Any edition, servicing, size, or hash difference fails the
job; there is no fallback to another compiler.

The workflow requires exactly one documented destination-test skip because a
public runner has no reviewed live UNC share. It also requires the PowerShell 7
negative-host probe to execute with no skip. Pull-request and ordinary push CI
upload no ZIP or EXE. An explicit `workflow_dispatch` from `main` with a valid
`release_version` may upload the unsigned ZIP and sidecar only after the full
gate passes. The result remains a candidate; publication still requires the
separate Windows VM matrix.

The source checkout may be dirty during development, but publication requires
`source_tree_state: clean`, an immutable source commit, identical results from
a second clean checkout, and the complete Hyper-V matrix. The private signer
must never be introduced into this repository or its CI secrets.
