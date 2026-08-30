[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
$script:Passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
    $script:Passed++
}

$install = Get-Content -LiteralPath (Join-Path $repoRoot 'Install-UserScoped.ps1') -Raw -Encoding UTF8
$uninstall = Get-Content -LiteralPath (Join-Path $repoRoot 'Uninstall-UserScoped.ps1') -Raw -Encoding UTF8
$common = Get-Content -LiteralPath (Join-Path $repoRoot 'PublicCommon.psm1') -Raw -Encoding UTF8

Assert-True ($install -match 'Invoke-TaipowerAMIRegistryGuardedUpdate64') 'installer uses Registry64 guarded update'
Assert-True ($uninstall -match 'Invoke-TaipowerAMIRegistryGuardedUpdate64') 'uninstaller uses Registry64 guarded update'
Assert-True ($install -notmatch '(?m)^\s*(SetValue|DeleteValue)\(') 'installer has no direct registry write'
Assert-True ($uninstall -notmatch '(?m)^\s*(SetValue|DeleteValue)\(') 'uninstaller has no direct registry write'

$installCommit = $install.LastIndexOf('$committed = $true', [StringComparison]::Ordinal)
$installCleanup = $install.IndexOf('foreach ($old in @($backupHost, $backupExtension))', [StringComparison]::Ordinal)
Assert-True ($installCommit -ge 0 -and $installCleanup -gt $installCommit) `
    'previous-version cleanup occurs only after install commit'

$uninstallCommit = $uninstall.LastIndexOf('$committed = $true', [StringComparison]::Ordinal)
$uninstallCleanup = $uninstall.IndexOf('foreach ($quarantine in @($hostQuarantine, $extensionQuarantine))', [StringComparison]::Ordinal)
Assert-True ($uninstallCommit -ge 0 -and $uninstallCleanup -gt $uninstallCommit) `
    'quarantine cleanup occurs only after uninstall commit'
Assert-True ($install -match 'rollback was incomplete') 'installer reports partial rollback without overwriting a conflict'
Assert-True ($uninstall -match 'rollback was incomplete') 'uninstaller reports partial rollback without overwriting a conflict'
Assert-True ($install -match 'Invoke-TaipowerAMIWithUserInstallMutex') `
    'installer places setup, transaction, and post-commit cleanup under the shared mutex wrapper'
Assert-True ($uninstall -match 'Invoke-TaipowerAMIWithUserInstallMutex') `
    'uninstaller places validation and transaction under the shared mutex wrapper'
Assert-True ($uninstall -notmatch '(?m)^\s*trap\s*\{') `
    'uninstaller does not rely on a trap for mutex release'
Assert-True ($uninstall -match 'Invoke-TaipowerAMIOrderedRollback') `
    'uninstaller uses dependency-gated rollback'
Assert-True ($common -match 'if \(\$filesReady\)' -and
    $common -match 'if \(\$filesReady -and \$configurationReady\)') `
    'rollback gates configuration on files and registration on configuration'

Write-Host ("Transaction structure tests passed: {0}" -f $script:Passed)
