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

Confirm that Chrome shows extension ID
`ajnbiemabobkigpbnfmoekolceigkica`. A different ID is a failed installation.

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
