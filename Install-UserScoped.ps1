[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string]$CredentialDestination,

    [string]$PackageRoot = ([IO.Path]::GetDirectoryName($PSScriptRoot)),

    [string]$LocalAppData = $env:LOCALAPPDATA
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PublicCommon.psm1') -Force
$constants = Get-TaipowerAMIPublicConstants

function Copy-ExactFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($name in $Names) {
        $sourcePath = Join-Path $Source $name
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw ('Package file is missing: ' + $name)
        }
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $Destination $name)
    }
}

$package = Test-TaipowerAMIUnsignedPackage -PackageRoot $PackageRoot
$destination = Resolve-TaipowerAMICredentialDestination `
    -Path $CredentialDestination `
    -RequireParent
$local = Resolve-TaipowerAMIAbsoluteLocalPath -Path $LocalAppData
$installRoot = Resolve-TaipowerAMIAbsoluteLocalPath `
    -Path (Join-Path $local 'TaipowerAMIV2') `
    -AllowMissing
$hostRoot = Join-Path $installRoot 'NativeHost'
$extensionRoot = Join-Path $installRoot 'ChromeExtension'
$finalExe = Join-Path $hostRoot $constants.NativeExeName
$finalManifest = Join-Path $hostRoot $constants.NativeManifestName

if (-not $PSCmdlet.ShouldProcess($installRoot, 'Install unsigned Taipower AMI Windows Companion for the current user')) {
    return
}
Invoke-TaipowerAMIWithUserInstallMutex -Action {
    [IO.Directory]::CreateDirectory($installRoot) | Out-Null
    Assert-TaipowerAMINoExistingReparseAncestor -LiteralPath $installRoot
    $transaction = [Guid]::NewGuid().ToString('N')
    $stageRoot = Join-Path $installRoot ('.installing-' + $transaction)
    $stageHost = Join-Path $stageRoot 'NativeHost'
    $stageExtension = Join-Path $stageRoot 'ChromeExtension'
    $backupHost = Join-Path $installRoot ('.previous-host-' + $transaction)
    $backupExtension = Join-Path $installRoot ('.previous-extension-' + $transaction)
    $oldRegistration = Get-TaipowerAMIRegistryValueSnapshot64 `
        -SubKey $constants.NativeRegistrationSubKey -ValueName ''
    $oldDestination = Get-TaipowerAMIRegistryValueSnapshot64 `
        -SubKey $constants.ConfigRegistrySubKey -ValueName $constants.ConfigRegistryValue
    if ($oldRegistration.Exists -and
        ($oldRegistration.Kind -ne [Microsoft.Win32.RegistryValueKind]::String -or
         [string]$oldRegistration.Value -cne $finalManifest)) {
        throw 'Native Messaging registration is not owned by this user-scoped installation; refusing to replace it.'
    }
    $installedRegistration = New-TaipowerAMIRegistrySnapshot `
        -Exists $true -Value $finalManifest -Kind ([Microsoft.Win32.RegistryValueKind]::String)
    $installedDestination = New-TaipowerAMIRegistrySnapshot `
        -Exists $true -Value $destination -Kind ([Microsoft.Win32.RegistryValueKind]::String)
    $hostBackedUp = $false
    $extensionBackedUp = $false
    $hostActivated = $false
    $extensionActivated = $false
    $destinationAttempted = $false
    $registrationAttempted = $false
    $committed = $false

    try {
    Copy-ExactFiles `
        -Source (Join-Path $package.Root 'NativeHost') `
        -Destination $stageHost `
        -Names @($constants.NativeExeName)
    Copy-ExactFiles `
        -Source $package.ExtensionRoot `
        -Destination $stageExtension `
        -Names @('manifest.json', 'background.js', 'popup.html', 'popup.js', 'popup.css')

    $manifest = New-TaipowerAMINativeManifest -ExecutablePath $finalExe
    Write-TaipowerAMIUtf8NoBom `
        -LiteralPath (Join-Path $stageHost $constants.NativeManifestName) `
        -Content (($manifest | ConvertTo-Json -Depth 5) + "`n")
    Test-TaipowerAMINativeManifest `
        -ManifestPath (Join-Path $stageHost $constants.NativeManifestName) `
        -ExpectedExecutablePath $finalExe | Out-Null

    if ((Get-TaipowerAMIFileHashHex -LiteralPath (Join-Path $stageHost $constants.NativeExeName)) `
        -cne $package.ExecutableSha256) {
        throw 'Staged Native Host does not match the reviewed package.'
    }

    if (Test-Path -LiteralPath $hostRoot) {
        Assert-TaipowerAMINoExistingReparseAncestor -LiteralPath $hostRoot
        Move-Item -LiteralPath $hostRoot -Destination $backupHost
        $hostBackedUp = $true
    }
    if (Test-Path -LiteralPath $extensionRoot) {
        Assert-TaipowerAMINoExistingReparseAncestor -LiteralPath $extensionRoot
        Move-Item -LiteralPath $extensionRoot -Destination $backupExtension
        $extensionBackedUp = $true
    }
    Move-Item -LiteralPath $stageHost -Destination $hostRoot
    $hostActivated = $true
    Move-Item -LiteralPath $stageExtension -Destination $extensionRoot
    $extensionActivated = $true

    Test-TaipowerAMINativeManifest `
        -ManifestPath $finalManifest `
        -ExpectedExecutablePath $finalExe | Out-Null
    if ((Get-TaipowerAMIFileHashHex -LiteralPath $finalExe) -cne $package.ExecutableSha256) {
        throw 'Activated Native Host does not match the reviewed package.'
    }

    $destinationAttempted = $true
    Invoke-TaipowerAMIRegistryGuardedUpdate64 `
        -SubKey $constants.ConfigRegistrySubKey `
        -ValueName $constants.ConfigRegistryValue `
        -Expected $oldDestination `
        -Desired $installedDestination
    $registrationAttempted = $true
    Invoke-TaipowerAMIRegistryGuardedUpdate64 `
        -SubKey $constants.NativeRegistrationSubKey `
        -ValueName '' `
        -Expected $oldRegistration `
        -Desired $installedRegistration

    $registration = Get-TaipowerAMIRegistryValueSnapshot64 `
        -SubKey $constants.NativeRegistrationSubKey -ValueName ''
    $configured = Get-TaipowerAMIRegistryValueSnapshot64 `
        -SubKey $constants.ConfigRegistrySubKey -ValueName $constants.ConfigRegistryValue
    if (-not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $registration -Expected $installedRegistration) -or
        -not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $configured -Expected $installedDestination)) {
        throw 'HKCU Registry64 post-install verification failed.'
    }
    $committed = $true
    } catch {
    $originalError = $_
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    if ($registrationAttempted) {
        try {
            $current = Get-TaipowerAMIRegistryValueSnapshot64 -SubKey $constants.NativeRegistrationSubKey -ValueName ''
            if (Test-TaipowerAMIRegistrySnapshotEqual -Actual $current -Expected $installedRegistration) {
                Invoke-TaipowerAMIRegistryGuardedUpdate64 `
                    -SubKey $constants.NativeRegistrationSubKey -ValueName '' `
                    -Expected $installedRegistration -Desired $oldRegistration
            } elseif (-not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $current -Expected $oldRegistration)) {
                throw 'Concurrent registration preserved.'
            }
        } catch { $rollbackErrors.Add('Native Messaging registration') }
    }
    if ($destinationAttempted) {
        try {
            $current = Get-TaipowerAMIRegistryValueSnapshot64 -SubKey $constants.ConfigRegistrySubKey -ValueName $constants.ConfigRegistryValue
            if (Test-TaipowerAMIRegistrySnapshotEqual -Actual $current -Expected $installedDestination) {
                Invoke-TaipowerAMIRegistryGuardedUpdate64 `
                    -SubKey $constants.ConfigRegistrySubKey `
                    -ValueName $constants.ConfigRegistryValue `
                    -Expected $installedDestination -Desired $oldDestination
            } elseif (-not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $current -Expected $oldDestination)) {
                throw 'Concurrent destination preserved.'
            }
        } catch { $rollbackErrors.Add('CredentialDestination') }
    }
    if ($rollbackErrors.Count -eq 0) {
        try {
            if ($extensionActivated -and (Test-Path -LiteralPath $extensionRoot)) { Remove-Item -LiteralPath $extensionRoot -Recurse -Force }
            if ($hostActivated -and (Test-Path -LiteralPath $hostRoot)) { Remove-Item -LiteralPath $hostRoot -Recurse -Force }
            if ($extensionBackedUp -and (Test-Path -LiteralPath $backupExtension)) { Move-Item -LiteralPath $backupExtension -Destination $extensionRoot }
            if ($hostBackedUp -and (Test-Path -LiteralPath $backupHost)) { Move-Item -LiteralPath $backupHost -Destination $hostRoot }
        } catch { $rollbackErrors.Add('filesystem') }
    }
    if ($rollbackErrors.Count -gt 0) {
        throw ('Install failed and rollback was incomplete: ' + ($rollbackErrors -join ', ') + '.')
    }
    throw $originalError
    } finally {
        if (Test-Path -LiteralPath $stageRoot) {
            try { Remove-Item -LiteralPath $stageRoot -Recurse -Force } catch {
                Write-Warning 'Staging cleanup was incomplete; no committed installation state was changed.'
            }
        }
    }

    if (-not $committed) { throw 'Install transaction did not commit.' }
    foreach ($old in @($backupHost, $backupExtension)) {
        if (Test-Path -LiteralPath $old) {
            try { Remove-Item -LiteralPath $old -Recurse -Force } catch {
                Write-Warning 'A previous-version backup could not be removed after commit.'
            }
        }
    }
    Write-Host 'Unsigned public Windows Companion installed for the current Chrome user.'
    Write-Host ('Load this unpacked extension in Chrome: ' + $extensionRoot)
}
