Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ExtensionId = 'ajnbiemabobkigpbnfmoekolceigkica'
$script:HostName = 'tw.taipower_ami.native_host_v2'
$script:AllowedOrigin = 'chrome-extension://ajnbiemabobkigpbnfmoekolceigkica/'
$script:ConfigRegistrySubKey = 'Software\TaipowerAMI'
$script:ConfigRegistryValue = 'CredentialDestination'
$script:NativeRegistrationSubKey =
    'Software\Google\Chrome\NativeMessagingHosts\tw.taipower_ami.native_host_v2'
$script:NativeExeName = 'TaipowerAMINativeHostV2.exe'
$script:NativeManifestName = 'native_host_manifest.json'
$script:InstallMutexPrefix = 'Local\TaipowerAMI.UserInstall.'

function Enter-TaipowerAMIUserInstallMutex {
    [CmdletBinding()]
    param([int]$TimeoutMilliseconds = 30000)

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = [Threading.Mutex]::new($false, ($script:InstallMutexPrefix + $sid))
    try {
        try {
            if (-not $mutex.WaitOne($TimeoutMilliseconds)) { throw 'Another install or uninstall is already running.' }
        } catch [Threading.AbandonedMutexException] {
            # The abandoned mutex is acquired by this thread; recovery validation still runs below.
        }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Exit-TaipowerAMIUserInstallMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Threading.Mutex]$Mutex)
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Invoke-TaipowerAMIWithUserInstallMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$TimeoutMilliseconds = 30000
    )

    $mutex = $null
    try {
        $mutex = Enter-TaipowerAMIUserInstallMutex -TimeoutMilliseconds $TimeoutMilliseconds
        & $Action
    } finally {
        if ($null -ne $mutex) {
            Exit-TaipowerAMIUserInstallMutex -Mutex $mutex
        }
    }
}

function Invoke-TaipowerAMIOrderedRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$RestoreFiles,
        [Parameter(Mandatory = $true)][scriptblock]$RestoreConfiguration,
        [Parameter(Mandatory = $true)][scriptblock]$RestoreRegistration
    )

    $errors = [Collections.Generic.List[string]]::new()
    $filesReady = $false
    $configurationReady = $false
    $registrationReady = $false

    try {
        & $RestoreFiles
        $filesReady = $true
    } catch {
        $errors.Add('filesystem')
    }

    if ($filesReady) {
        try {
            & $RestoreConfiguration
            $configurationReady = $true
        } catch {
            $errors.Add('CredentialDestination')
        }
    }

    if ($filesReady -and $configurationReady) {
        try {
            & $RestoreRegistration
            $registrationReady = $true
        } catch {
            $errors.Add('Native Messaging registration')
        }
    }

    return [pscustomobject]@{
        Errors = @($errors)
        FilesReady = $filesReady
        ConfigurationReady = $configurationReady
        RegistrationReady = $registrationReady
    }
}

function Get-TaipowerAMIPublicConstants {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        ExtensionId = $script:ExtensionId
        HostName = $script:HostName
        AllowedOrigin = $script:AllowedOrigin
        ConfigRegistrySubKey = $script:ConfigRegistrySubKey
        ConfigRegistryValue = $script:ConfigRegistryValue
        NativeRegistrationSubKey = $script:NativeRegistrationSubKey
        NativeExeName = $script:NativeExeName
        NativeManifestName = $script:NativeManifestName
    }
}

function New-TaipowerAMIRegistrySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Exists,
        [AllowNull()]$Value,
        [AllowNull()]$Kind
    )

    [pscustomobject]@{
        Exists = $Exists
        Value = $Value
        Kind = $Kind
    }
}

function Get-TaipowerAMIRegistryValueSnapshotFromKey {
    [CmdletBinding()]
    param(
        [AllowNull()][Microsoft.Win32.RegistryKey]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ValueName
    )

    if ($null -eq $Key -or -not ($Key.GetValueNames() -ccontains $ValueName)) {
        return New-TaipowerAMIRegistrySnapshot -Exists $false -Value $null -Kind $null
    }
    return New-TaipowerAMIRegistrySnapshot `
        -Exists $true `
        -Value ($Key.GetValue(
            $ValueName,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )) `
        -Kind ($Key.GetValueKind($ValueName))
}

function Test-TaipowerAMIRegistrySnapshotEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected
    )

    if ([bool]$Actual.Exists -ne [bool]$Expected.Exists) { return $false }
    if (-not [bool]$Actual.Exists) { return $true }
    if ($Actual.Kind -ne $Expected.Kind) { return $false }
    if ($Actual.Value -is [byte[]] -or $Expected.Value -is [byte[]]) {
        if (-not ($Actual.Value -is [byte[]]) -or -not ($Expected.Value -is [byte[]])) {
            return $false
        }
        return [Linq.Enumerable]::SequenceEqual(
            [byte[]]$Actual.Value,
            [byte[]]$Expected.Value
        )
    }
    return [object]::Equals($Actual.Value, $Expected.Value)
}

function Get-TaipowerAMIRegistryValueSnapshot64 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ValueName
    )

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $key = $base.OpenSubKey($SubKey, $false)
        try {
            return Get-TaipowerAMIRegistryValueSnapshotFromKey -Key $key -ValueName $ValueName
        } finally {
            if ($null -ne $key) { $key.Dispose() }
        }
    } finally {
        $base.Dispose()
    }
}

function Invoke-TaipowerAMIRegistryGuardedUpdate64 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ValueName,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Desired
    )

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $key = $base.OpenSubKey($SubKey, $true)
        if ($null -eq $key -and [bool]$Desired.Exists) {
            $key = $base.CreateSubKey($SubKey, $true)
        }
        try {
            $actual = Get-TaipowerAMIRegistryValueSnapshotFromKey -Key $key -ValueName $ValueName
            if (-not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $actual -Expected $Expected)) {
                throw 'Registry64 guarded update rejected a concurrent or foreign value.'
            }
            if ([bool]$Desired.Exists) {
                if ($null -eq $key) {
                    throw 'Registry64 guarded update could not open the destination key.'
                }
                $key.SetValue($ValueName, $Desired.Value, $Desired.Kind)
            } elseif ($null -ne $key) {
                $key.DeleteValue($ValueName, $false)
            }
            $observed = Get-TaipowerAMIRegistryValueSnapshotFromKey -Key $key -ValueName $ValueName
            if (-not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $observed -Expected $Desired)) {
                throw 'Registry64 guarded update postcondition failed.'
            }
        } finally {
            if ($null -ne $key) { $key.Dispose() }
        }
    } finally {
        $base.Dispose()
    }
}

function Test-TaipowerAMIReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-TaipowerAMINoExistingReparseAncestor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $cursor = $LiteralPath
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            if (Test-TaipowerAMIReparsePoint -LiteralPath $cursor) {
                throw 'The configured path or one of its existing ancestors is a reparse point.'
            }
        }

        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            [string]::Equals($parent, $cursor, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $cursor = $parent
    }
}

function Resolve-TaipowerAMICredentialDestination {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireParent
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) {
        throw 'CredentialDestination is empty or contains an invalid character.'
    }
    if ($Path -match '%[^%]+%') {
        throw 'CredentialDestination must not contain environment-variable expansion.'
    }
    if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith('\\.\', [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Device and extended-length paths are not accepted.'
    }
    $driveQualified = $Path.Length -ge 3 -and
        [char]::IsLetter($Path[0]) -and
        $Path[1] -eq ':' -and
        ($Path[2] -eq '\' -or $Path[2] -eq '/')
    $uncQualified = $Path.StartsWith('\\', [StringComparison]::Ordinal) -and $Path.Length -gt 2
    if (-not $driveQualified -and -not $uncQualified) {
        throw 'CredentialDestination must be an absolute local or UNC path.'
    }

    $full = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($pathRoot) -or
        $full.Substring($pathRoot.Length).IndexOf(':') -ge 0) {
        throw 'CredentialDestination contains an invalid path component.'
    }
    if ($driveQualified) {
        try {
            if ([IO.DriveInfo]::new($pathRoot).DriveType -eq [IO.DriveType]::Network) {
                throw 'Network CredentialDestination values must use a native UNC path.'
            }
        } catch {
            if ($_.Exception.Message -eq 'Network CredentialDestination values must use a native UNC path.') {
                throw
            }
            throw 'CredentialDestination drive could not be verified.'
        }
    }
    if (-not [string]::Equals(
        [IO.Path]::GetFileName($full),
        'credentials.json',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'CredentialDestination must end with the exact filename credentials.json.'
    }
    foreach ($segment in $full.Substring($pathRoot.Length).Split(
        [char[]]@('\', '/'),
        [StringSplitOptions]::RemoveEmptyEntries
    )) {
        if ($segment.EndsWith('.', [StringComparison]::Ordinal) -or
            $segment.EndsWith(' ', [StringComparison]::Ordinal)) {
            throw 'CredentialDestination contains an invalid path component.'
        }
    }
    if ($uncQualified) {
        $uncParts = $full.Substring(2).Split(
            [char[]]@('\', '/'),
            [StringSplitOptions]::RemoveEmptyEntries
        )
        if ($uncParts.Length -lt 3) {
            throw 'CredentialDestination UNC path must include server, share, and credentials.json.'
        }
    }

    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw 'CredentialDestination must have a parent directory.'
    }
    if ($RequireParent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw 'CredentialDestination parent directory does not exist or is unavailable.'
    }

    Assert-TaipowerAMINoExistingReparseAncestor -LiteralPath $full
    return $full
}

function Resolve-TaipowerAMIAbsoluteLocalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0 -or
        -not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) {
        throw 'Expected an absolute local path.'
    }
    if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith('\\.\', [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Device and extended-length paths are not accepted.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $full)) {
        throw 'Required local path does not exist.'
    }
    Assert-TaipowerAMINoExistingReparseAncestor -LiteralPath $full
    return $full
}

function Get-TaipowerAMIFileHashHex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Write-TaipowerAMIUtf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [IO.File]::WriteAllText(
        $LiteralPath,
        $Content,
        [Text.UTF8Encoding]::new($false, $true)
    )
}

function Test-TaipowerAMIExtensionBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ExtensionRoot)

    $root = Resolve-TaipowerAMIAbsoluteLocalPath -Path $ExtensionRoot
    $required = @('manifest.json', 'background.js', 'popup.html', 'popup.js', 'popup.css')
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) {
            throw ('Chrome extension is missing required file: ' + $name)
        }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.manifest_version -ne 3 -or
        [string]::IsNullOrWhiteSpace([string]$manifest.key) -or
        @($manifest.host_permissions).Count -ne 1 -or
        [string]$manifest.host_permissions[0] -cne 'https://service.taipower.com.tw/*') {
        throw 'Chrome extension manifest violates the public compatibility contract.'
    }
    $background = Get-Content -LiteralPath (Join-Path $root 'background.js') -Raw -Encoding UTF8
    if ($background -notmatch [regex]::Escape($script:HostName)) {
        throw 'Chrome extension does not use the fixed Native Messaging host name.'
    }
    return [pscustomobject]@{ Root = $root; Files = $required }
}

function New-TaipowerAMINativeManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ExecutablePath)

    $exe = Resolve-TaipowerAMIAbsoluteLocalPath -Path $ExecutablePath -AllowMissing
    if ([IO.Path]::GetFileName($exe) -cne $script:NativeExeName) {
        throw 'Native Host manifest executable name is invalid.'
    }
    [ordered]@{
        name = $script:HostName
        description = 'Taipower AMI credential handoff to local Home Assistant'
        path = $exe
        type = 'stdio'
        allowed_origins = @($script:AllowedOrigin)
    }
}

function Test-TaipowerAMINativeManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutablePath
    )

    $manifestFile = Resolve-TaipowerAMIAbsoluteLocalPath -Path $ManifestPath
    $expectedExe = Resolve-TaipowerAMIAbsoluteLocalPath -Path $ExpectedExecutablePath -AllowMissing
    $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.name -cne $script:HostName -or
        [string]$manifest.type -cne 'stdio' -or
        @($manifest.allowed_origins).Count -ne 1 -or
        [string]$manifest.allowed_origins[0] -cne $script:AllowedOrigin -or
        [string]$manifest.path -cne $expectedExe) {
        throw 'Native Host manifest violates the public compatibility contract.'
    }
    return $manifest
}

function Test-TaipowerAMIUnsignedPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $root = Resolve-TaipowerAMIAbsoluteLocalPath -Path $PackageRoot
    $metadataPath = Join-Path $root 'release_metadata.json'
    $sumsPath = Join-Path $root 'SHA256SUMS'
    $exePath = Join-Path $root 'NativeHost\TaipowerAMINativeHostV2.exe'
    $releaseReadmePath = Join-Path $root 'README.md'
    $installationPath = Join-Path $root 'INSTALLATION.md'
    $securityPath = Join-Path $root 'SECURITY.md'
    $privacyPath = Join-Path $root 'PRIVACY.md'
    $codeSigningPolicyPath = Join-Path $root 'CODE_SIGNING_POLICY.md'
    $licensePath = Join-Path $root 'LICENSE'
    foreach ($path in @(
        $metadataPath,
        $sumsPath,
        $exePath,
        $releaseReadmePath,
        $installationPath,
        $securityPath,
        $privacyPath,
        $codeSigningPolicyPath,
        $licensePath
    )) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Unsigned release package is incomplete.'
        }
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$metadata.schema_version -ne 1 -or
        [string]$metadata.release_channel -cne 'public_unsigned' -or
        [bool]$metadata.signed -ne $false -or
        [string]$metadata.extension_id -cne $script:ExtensionId -or
        [string]$metadata.native_host_name -cne $script:HostName -or
        @($metadata.allowed_origins).Count -ne 1 -or
        [string]$metadata.allowed_origins[0] -cne $script:AllowedOrigin) {
        throw 'Release metadata violates the public unsigned contract.'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $exePath
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::NotSigned) {
        throw 'The public installer accepts only the reviewed unsigned Native Host.'
    }
    $exeHash = Get-TaipowerAMIFileHashHex -LiteralPath $exePath
    if ($exeHash -cne ([string]$metadata.native_host_sha256).ToUpperInvariant()) {
        throw 'Native Host hash does not match release metadata.'
    }

    $expected = @{}
    foreach ($line in Get-Content -LiteralPath $sumsPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -cnotmatch '^([0-9A-F]{64})  ([^\\].+)$') {
            throw 'SHA256SUMS contains an invalid line.'
        }
        $relative = $Matches[2].Replace('/', '\')
        if ([IO.Path]::IsPathRooted($relative) -or
            $relative.Split('\') -contains '..' -or
            $expected.ContainsKey($relative)) {
            throw 'SHA256SUMS contains an unsafe or duplicate path.'
        }
        $expected[$relative] = $Matches[1]
    }

    $actualFiles = Get-ChildItem -LiteralPath $root -File -Recurse |
        Where-Object -Property FullName -CNE -Value $sumsPath
    if ($actualFiles.Count -ne $expected.Count) {
        throw 'SHA256SUMS does not cover the package exactly.'
    }
    foreach ($file in $actualFiles) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\')
        if (-not $expected.ContainsKey($relative) -or
            (Get-TaipowerAMIFileHashHex -LiteralPath $file.FullName) -cne $expected[$relative]) {
            throw ('Release checksum validation failed for: ' + $relative)
        }
    }

    $extension = Test-TaipowerAMIExtensionBundle -ExtensionRoot (Join-Path $root 'ChromeExtension')
    return [pscustomobject]@{
        Root = $root
        Metadata = $metadata
        ExecutablePath = $exePath
        ExecutableSha256 = $exeHash
        ExtensionRoot = $extension.Root
    }
}
