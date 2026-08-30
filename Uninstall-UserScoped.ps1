[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$RemoveExtension,
    [string]$LocalAppData = $env:LOCALAPPDATA
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PublicCommon.psm1') -Force
$constants = Get-TaipowerAMIPublicConstants
$absent = New-TaipowerAMIRegistrySnapshot -Exists $false -Value $null -Kind $null

if (-not $PSCmdlet.ShouldProcess($LocalAppData, 'Uninstall Taipower AMI Windows Companion for the current user')) {
    return
}

Invoke-TaipowerAMIWithUserInstallMutex -Action {
    $local = Resolve-TaipowerAMIAbsoluteLocalPath -Path $LocalAppData
    $installRoot = Resolve-TaipowerAMIAbsoluteLocalPath `
        -Path (Join-Path $local 'TaipowerAMIV2') `
        -AllowMissing
    $hostRoot = Join-Path $installRoot 'NativeHost'
    $extensionRoot = Join-Path $installRoot 'ChromeExtension'
    $expectedExe = Join-Path $hostRoot $constants.NativeExeName
    $expectedManifest = Join-Path $hostRoot $constants.NativeManifestName
    $transaction = [Guid]::NewGuid().ToString('N')
    $hostQuarantine = Join-Path $installRoot ('.uninstalling-host-' + $transaction)
    $extensionQuarantine = Join-Path $installRoot ('.uninstalling-extension-' + $transaction)

    foreach ($path in @($installRoot, $hostRoot, $extensionRoot, $hostQuarantine, $extensionQuarantine)) {
        Assert-TaipowerAMINoExistingReparseAncestor -LiteralPath $path
    }

    $registration = Get-TaipowerAMIRegistryValueSnapshot64 `
        -SubKey $constants.NativeRegistrationSubKey -ValueName ''
    $configuration = Get-TaipowerAMIRegistryValueSnapshot64 `
        -SubKey $constants.ConfigRegistrySubKey -ValueName $constants.ConfigRegistryValue

    if ($registration.Exists -and
        ($registration.Kind -ne [Microsoft.Win32.RegistryValueKind]::String -or
         [string]$registration.Value -cne $expectedManifest)) {
        throw 'Native Messaging registration is not owned by this user-scoped installation; refusing to remove it.'
    }
    if ($configuration.Exists -and
        $configuration.Kind -ne [Microsoft.Win32.RegistryValueKind]::String) {
        throw 'CredentialDestination has an unexpected registry type; refusing partial removal.'
    }

    $hostMoved = $false
    $extensionMoved = $false
    $registrationAttempted = $false
    $configurationAttempted = $false
    $committed = $false
    try {
        if (Test-Path -LiteralPath $hostRoot) {
            Move-Item -LiteralPath $hostRoot -Destination $hostQuarantine
            $hostMoved = $true
        }
        if ($RemoveExtension -and (Test-Path -LiteralPath $extensionRoot)) {
            Move-Item -LiteralPath $extensionRoot -Destination $extensionQuarantine
            $extensionMoved = $true
        }

        $registrationAttempted = $true
        Invoke-TaipowerAMIRegistryGuardedUpdate64 `
            -SubKey $constants.NativeRegistrationSubKey -ValueName '' `
            -Expected $registration -Desired $absent
        $configurationAttempted = $true
        Invoke-TaipowerAMIRegistryGuardedUpdate64 `
            -SubKey $constants.ConfigRegistrySubKey `
            -ValueName $constants.ConfigRegistryValue `
            -Expected $configuration -Desired $absent

        $observedRegistration = Get-TaipowerAMIRegistryValueSnapshot64 `
            -SubKey $constants.NativeRegistrationSubKey -ValueName ''
        $observedConfiguration = Get-TaipowerAMIRegistryValueSnapshot64 `
            -SubKey $constants.ConfigRegistrySubKey -ValueName $constants.ConfigRegistryValue
        if (-not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $observedRegistration -Expected $absent) -or
            -not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $observedConfiguration -Expected $absent)) {
            throw 'HKCU Registry64 post-uninstall verification failed.'
        }
        $committed = $true
    } catch {
        $originalError = $_
        $rollback = Invoke-TaipowerAMIOrderedRollback `
            -RestoreFiles ({
                if ($hostMoved -and (Test-Path -LiteralPath $hostQuarantine)) {
                    Move-Item -LiteralPath $hostQuarantine -Destination $hostRoot
                }
                if ($extensionMoved -and (Test-Path -LiteralPath $extensionQuarantine)) {
                    Move-Item -LiteralPath $extensionQuarantine -Destination $extensionRoot
                }

                if ($hostMoved -or $registration.Exists) {
                    if (-not (Test-Path -LiteralPath $expectedExe -PathType Leaf) -or
                        -not (Test-Path -LiteralPath $expectedManifest -PathType Leaf)) {
                        throw 'Restored Native Host files are incomplete.'
                    }
                    Assert-TaipowerAMINoExistingReparseAncestor -LiteralPath $hostRoot
                    Test-TaipowerAMINativeManifest `
                        -ManifestPath $expectedManifest `
                        -ExpectedExecutablePath $expectedExe | Out-Null
                }
                if ($extensionMoved) {
                    Test-TaipowerAMIExtensionBundle -ExtensionRoot $extensionRoot | Out-Null
                }
            }.GetNewClosure()) `
            -RestoreConfiguration ({
                if ($configurationAttempted) {
                    $current = Get-TaipowerAMIRegistryValueSnapshot64 `
                        -SubKey $constants.ConfigRegistrySubKey `
                        -ValueName $constants.ConfigRegistryValue
                    if (Test-TaipowerAMIRegistrySnapshotEqual -Actual $current -Expected $configuration) {
                        return
                    }
                    if (-not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $current -Expected $absent)) {
                        throw 'Concurrent destination preserved.'
                    }
                    Invoke-TaipowerAMIRegistryGuardedUpdate64 `
                        -SubKey $constants.ConfigRegistrySubKey `
                        -ValueName $constants.ConfigRegistryValue `
                        -Expected $absent -Desired $configuration
                }
            }.GetNewClosure()) `
            -RestoreRegistration ({
                if ($registrationAttempted) {
                    $current = Get-TaipowerAMIRegistryValueSnapshot64 `
                        -SubKey $constants.NativeRegistrationSubKey -ValueName ''
                    if (Test-TaipowerAMIRegistrySnapshotEqual -Actual $current -Expected $registration) {
                        return
                    }
                    if (-not (Test-TaipowerAMIRegistrySnapshotEqual -Actual $current -Expected $absent)) {
                        throw 'Concurrent registration preserved.'
                    }
                    Invoke-TaipowerAMIRegistryGuardedUpdate64 `
                        -SubKey $constants.NativeRegistrationSubKey -ValueName '' `
                        -Expected $absent -Desired $registration
                }
            }.GetNewClosure())

        if ($rollback.Errors.Count -gt 0) {
            throw ('Uninstall failed and rollback was incomplete: ' + ($rollback.Errors -join ', ') + '.')
        }
        throw $originalError
    }

    if (-not $committed) { throw 'Uninstall transaction did not commit.' }
    foreach ($quarantine in @($hostQuarantine, $extensionQuarantine)) {
        if (Test-Path -LiteralPath $quarantine) {
            try { Remove-Item -LiteralPath $quarantine -Recurse -Force } catch {
                Write-Warning 'A quarantined component could not be removed after commit.'
            }
        }
    }
    if (Test-Path -LiteralPath $installRoot -PathType Container) {
        try {
            $remaining = @(Get-ChildItem -LiteralPath $installRoot -Force)
            if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $installRoot -Force }
        } catch { Write-Warning 'The empty installation root could not be removed after commit.' }
    }

    Write-Host 'User-scoped Native Host, registration, and destination setting removed.'
    if (-not $RemoveExtension) {
        Write-Host ('The unpacked Chrome extension was retained at: ' + $extensionRoot)
    }
}
