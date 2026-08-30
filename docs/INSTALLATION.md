# User-scoped installation

This public channel is deliberately unsigned and never elevates. Use it first
in a disposable patched Windows VM. Production Program Files deployment,
signed releases, YubiKey operations, and WDAC belong to a separate private
workflow and are not implemented here.

## Prerequisites

- Windows with 64-bit Chrome 120 or newer;
- one extracted, reviewed public unsigned release;
- an existing destination directory writable by the Chrome user; and
- a Home Assistant integration configured to import the resulting schema-v1
  `credentials.json` file.

The installer will not create the destination directory or test Home
Assistant credentials. A UNC destination therefore requires working SMB
access under the same ordinary Windows account that runs Chrome. Use the
native `\\server\share\...` form; mapped network-drive letters are rejected so
the Native Host and installer cannot resolve the same destination through
different names.

## Verify, unblock, and extract the archive

Download the `.zip` and its matching `.zip.sha256` sidecar into the same
directory. Compare the expected SHA-256 with an independently obtained value
from the reviewed release record when one is available. A sidecar downloaded
from the same location detects an incomplete or accidentally changed download,
but does not by itself authenticate an unsigned publisher.

In Windows PowerShell, replace the example filename with the exact archive you
downloaded. This check also requires the filename recorded by the sidecar to
match the archive:

```powershell
$zip = (Resolve-Path -LiteralPath '.\taipower-ami-windows-2.0.1-unsigned.zip').Path
$sidecar = $zip + '.sha256'

if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
  throw 'Matching .zip.sha256 sidecar was not found.'
}

$record = (Get-Content -LiteralPath $sidecar -Raw -Encoding UTF8).TrimEnd([char[]]"`r`n")
if ($record -cnotmatch '^([0-9A-F]{64})  ([^\\/]+\.zip)$') {
  throw 'The SHA-256 sidecar has an unexpected format.'
}

$expectedHash = $Matches[1]
$expectedName = $Matches[2]
if ($expectedName -cne [IO.Path]::GetFileName($zip)) {
  throw 'The SHA-256 sidecar names a different archive.'
}

$actualHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actualHash -cne $expectedHash) {
  throw "SHA-256 mismatch. Expected $expectedHash but received $actualHash."
}

Write-Host "Verified SHA-256: $actualHash"
```

Only after that exact ZIP verifies, remove Mark-of-the-Web from that ZIP and
extract it into a new directory:

```powershell
$destination = Join-Path (Get-Location) 'taipower-ami-windows-2.0.1-review'
if (Test-Path -LiteralPath $destination) {
  throw "Refusing to reuse an existing extraction directory: $destination"
}

Unblock-File -LiteralPath $zip
Expand-Archive -LiteralPath $zip -DestinationPath $destination
Set-Location -LiteralPath $destination
```

Do not recursively run `Unblock-File` over Downloads, a user profile, or an
existing extraction tree. If the ZIP was extracted before it was verified and
unblocked, discard that extraction and repeat the exact-file procedure above
into a new directory.

## Install

From the extracted release root, run Windows PowerShell as the ordinary Chrome
user:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned `
  -File .\Installer\Install-UserScoped.ps1 `
  -CredentialDestination '\\server\share\taipower-ami\credentials.json'
```

The installer validates every packaged file against `SHA256SUMS`, confirms
that the Native Host is unsigned, stages both components, atomically replaces
the user-owned component directories, and finally writes two values in the
64-bit HKCU registry view:

- `Software\Google\Chrome\NativeMessagingHosts\tw.taipower_ami.native_host_v2`
  default value -> the absolute installed manifest path;
- `Software\TaipowerAMI` / `CredentialDestination` (`REG_SZ`) -> the
  validated handoff path.

Load the unpacked extension from the path printed by the installer:

`%LOCALAPPDATA%\TaipowerAMIV2\ChromeExtension`

Complete the Chrome step explicitly:

1. Open `chrome://extensions` in the same Chrome profile that will use the
   Taipower website.
2. Turn on **Developer mode** in the upper-right corner.
3. Select **Load unpacked**.
4. In the folder picker, select the installed `ChromeExtension` directory at
   `%LOCALAPPDATA%\TaipowerAMIV2\ChromeExtension`, then choose **Select Folder**.
   In the source repository this bundle is named `chrome_extension`; do not
   select the ZIP, the release root, or the `NativeHost` directory.
5. Confirm that Chrome shows extension ID
   `ajnbiemabobkigpbnfmoekolceigkica`. A different ID is a failed installation:
   remove that extension entry and stop rather than continuing the handoff.

Chrome may retain an older unpacked entry. Keep only the reviewed entry whose
path and fixed ID match the values above.

## Uninstall

Run the uninstaller from the extracted release's `Installer` directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned `
  -File .\Uninstall-UserScoped.ps1
```

This removes the exact owned Native Messaging registration, Native Host, and
destination setting. It does not delete `credentials.json` or its parent
directory. The unpacked extension is retained by default; add
`-RemoveExtension` to remove its LocalAppData bundle as well, then remove the
entry from `chrome://extensions` if Chrome still lists it.

The uninstaller refuses to delete a registration that does not point to this
installation's exact manifest path and never deletes parent Chrome registry
keys.
