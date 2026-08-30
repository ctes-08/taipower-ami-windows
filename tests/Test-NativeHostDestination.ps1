[CmdletBinding()]
param(
    [string]$ToolchainRoot = 'C:\Program Files\Microsoft Visual Studio\18\Community',
    [string]$ProgramFilesX86 = ${env:ProgramFiles(x86)}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
$sourcePath = Join-Path $repoRoot 'src\NativeHostLauncher.cs'
$script:Passed = 0
$script:Skipped = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
    $script:Passed++
}

$sourceText = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
Assert-True ($sourceText -match 'RegistryView\.Registry64') 'runtime fixes HKCU configuration to Registry64'
Assert-True ($sourceText -match 'Software\\TaipowerAMI') 'runtime uses the public configuration registry contract'
Assert-True ($sourceText -match 'CredentialDestination') 'runtime reads the exact CredentialDestination value'
Assert-True ($sourceText -match 'RegistryValueOptions\.DoNotExpandEnvironmentNames') 'runtime forbids registry environment expansion'
Assert-True ($sourceText -match 'FileAttributes\.ReparsePoint') 'runtime rejects reparse-point ancestry and destination files'
Assert-True ($sourceText -match 'GetFinalPathNameByHandle') 'runtime resolves the opened parent directory by handle'
Assert-True ($sourceText -match 'CleanupStaleCredentialTemporaryFiles') 'runtime performs bounded stale credential temporary cleanup'
Assert-True ($sourceText -match 'MaxCredentialTemporaryCandidates\s*=\s*256') 'runtime bounds stale temporary enumeration'
Assert-True ($sourceText -match 'MaxCredentialTemporaryBytes\s*=\s*64\s*\*\s*1024') 'runtime limits stale temporary cleanup to small files'
Assert-True ($sourceText -match 'StaleCredentialTemporaryMinimumAgeMinutes\s*=\s*5') 'runtime does not clean recent handoff temporaries'
Assert-True ($sourceText -match 'FileAttributes\.Directory[\s\S]*FileAttributes\.Device[\s\S]*FileAttributes\.ReparsePoint') 'runtime cleanup retains directories, devices, and reparse points'
Assert-True ($sourceText -match "character >= 'a'.*character <= 'f'") 'runtime cleanup accepts only lowercase hexadecimal temporary names'
Assert-True `
    ([regex]::Matches($sourceText, 'ConfirmCredentialDestination\(destination\)').Count -ge 3) `
    'runtime rechecks the registry destination before and during atomic handoff'
Assert-True ($sourceText -match 'DriveType\.Network') 'runtime requires native UNC rather than a mapped network drive'
Assert-True ($sourceText -notmatch '192\.168\.[0-9]+\.[0-9]+') 'runtime contains no household IPv4 address'
Assert-True ($sourceText -notmatch '\\\\192\.168\.') 'runtime contains no household UNC path'
Assert-True ($sourceText -notmatch 'Console\.Error|Console\.Write(?:Line)?\(') 'runtime has no unframed console secret-output path'

$testRoot = Join-Path $repoRoot ('.test-output\destination-' + [Guid]::NewGuid().ToString('N'))
$releaseOutput = Join-Path $testRoot 'release'
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    $release = & (Join-Path $repoRoot 'Build-UnsignedRelease.ps1') `
        -Version '0.0.0-destination-test' `
        -OutputDirectory $releaseOutput `
        -ToolchainRoot $ToolchainRoot `
        -ProgramFilesX86 $ProgramFilesX86
    $exePath = Join-Path $release.Package 'NativeHost\TaipowerAMINativeHostV2.exe'
    $childScript = Join-Path $PSScriptRoot 'Invoke-NativeHostDestinationChecks.ps1'
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childOutput = @(& $windowsPowerShell `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $childScript `
        -ExecutablePath $exePath `
        -TestRoot (Join-Path $testRoot 'runtime'))
    if ($LASTEXITCODE -ne 0) {
        throw ('Native Host destination child test failed.' + [Environment]::NewLine +
            ($childOutput -join [Environment]::NewLine))
    }
    $childText = $childOutput -join [Environment]::NewLine
    $summaryMatch = [regex]::Match(
        $childText,
        '(?m)^PASS_COUNT=([0-9]+);SKIP_COUNT=([0-9]+)$'
    )
    Assert-True $summaryMatch.Success 'runtime child test returned a structured summary'
    $script:Passed += [int]$summaryMatch.Groups[1].Value
    $script:Skipped += [int]$summaryMatch.Groups[2].Value
    Write-Host $childText
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host ("Native Host destination tests passed: {0}; skipped: {1}" -f $script:Passed, $script:Skipped)
