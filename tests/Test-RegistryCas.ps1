[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
Import-Module (Join-Path $repoRoot 'PublicCommon.psm1') -Force
$script:Passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
    $script:Passed++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    try { & $Action; throw ('ASSERTION FAILED: ' + $Message) } catch {
        if ($_.Exception.Message.StartsWith('ASSERTION FAILED:', [StringComparison]::Ordinal)) { throw }
    }
    $script:Passed++
}

$subKey = 'Software\TaipowerAMI\Tests\' + [Guid]::NewGuid().ToString('N')
$name = 'CasValue'
$absent = New-TaipowerAMIRegistrySnapshot -Exists $false -Value $null -Kind $null
$v1 = New-TaipowerAMIRegistrySnapshot -Exists $true -Value 'v1' -Kind ([Microsoft.Win32.RegistryValueKind]::String)
$v2 = New-TaipowerAMIRegistrySnapshot -Exists $true -Value 'v2' -Kind ([Microsoft.Win32.RegistryValueKind]::String)
$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::CurrentUser,
    [Microsoft.Win32.RegistryView]::Registry64
)
try {
    Invoke-TaipowerAMIRegistryGuardedUpdate64 -SubKey $subKey -ValueName $name -Expected $absent -Desired $v1
    Assert-True (Test-TaipowerAMIRegistrySnapshotEqual `
        -Actual (Get-TaipowerAMIRegistryValueSnapshot64 -SubKey $subKey -ValueName $name) `
        -Expected $v1) 'exact absent-to-string guarded update succeeds'

    $key = $base.OpenSubKey($subKey, $true)
    try { $key.SetValue($name, 'v2', [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
    Assert-Throws {
        Invoke-TaipowerAMIRegistryGuardedUpdate64 -SubKey $subKey -ValueName $name -Expected $v1 -Desired $absent
    } 'concurrent string replacement rejects stale delete'
    Assert-True (Test-TaipowerAMIRegistrySnapshotEqual `
        -Actual (Get-TaipowerAMIRegistryValueSnapshot64 -SubKey $subKey -ValueName $name) `
        -Expected $v2) 'foreign/newer string is preserved after a rejected guarded update'

    $key = $base.OpenSubKey($subKey, $true)
    try { $key.SetValue($name, 7, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
    Assert-Throws {
        Invoke-TaipowerAMIRegistryGuardedUpdate64 -SubKey $subKey -ValueName $name -Expected $v2 -Desired $absent
    } 'registry kind change rejects stale delete'
    $dword = Get-TaipowerAMIRegistryValueSnapshot64 -SubKey $subKey -ValueName $name
    Assert-True ($dword.Exists -and $dword.Kind -eq [Microsoft.Win32.RegistryValueKind]::DWord -and $dword.Value -eq 7) `
        'foreign registry kind and value remain untouched'

    Invoke-TaipowerAMIRegistryGuardedUpdate64 -SubKey $subKey -ValueName $name -Expected $dword -Desired $absent
    Assert-True (-not (Get-TaipowerAMIRegistryValueSnapshot64 -SubKey $subKey -ValueName $name).Exists) `
        'exact delete guarded update succeeds'
} finally {
    try { $base.DeleteSubKeyTree($subKey, $false) } finally { $base.Dispose() }
}

Write-Host ("Registry guarded-update tests passed: {0}" -f $script:Passed)
