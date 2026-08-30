[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
$builder = Join-Path $repoRoot 'Build-UnsignedRelease.ps1'
$testRoot = Join-Path $repoRoot ('.test-output\build-host-gate-' + [Guid]::NewGuid().ToString('N'))
$rejectedOutput = Join-Path $testRoot 'rejected-output'
$buildRoot = Join-Path $repoRoot '.build'
$script:Passed = 0
$script:Skipped = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
    $script:Passed++
}

function Get-BuildEntries {
    if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $buildRoot -Force |
        ForEach-Object { $_.Name } |
        Sort-Object)
}

function Quote-NativeArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -eq $pwsh) {
    $script:Skipped++
    Write-Warning 'PowerShell 7 is unavailable; the actual pwsh.exe rejection probe was skipped.'
} else {
    $beforeBuildEntries = @(Get-BuildEntries)
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $pwsh.Source
        $startInfo.Arguments = @(
            '-NoLogo'
            '-NoProfile'
            '-NonInteractive'
            '-ExecutionPolicy Bypass'
            '-File ' + (Quote-NativeArgument -Value $builder)
            '-Version 0.0.0-host-gate'
            '-OutputDirectory ' + (Quote-NativeArgument -Value $rejectedOutput)
        ) -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        Assert-True $process.Start() 'PowerShell 7 rejection probe starts'
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $combinedOutput = $standardOutput + "`n" + $standardError

        Assert-True ($process.ExitCode -ne 0) 'PowerShell 7 builder invocation is rejected'
        Assert-True (
            $combinedOutput -match [regex]::Escape('require 64-bit Windows PowerShell 5.1 Desktop')
        ) 'PowerShell 7 rejection reports the supported build host'
        Assert-True (-not (Test-Path -LiteralPath $rejectedOutput)) `
            'unsupported host is rejected before creating release output'
        Assert-True (
            (@(Get-BuildEntries) -join "`n") -ceq ($beforeBuildEntries -join "`n")
        ) 'unsupported host is rejected before creating a staging directory'
    } finally {
        if (Test-Path -LiteralPath $testRoot) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }
}

Write-Host ("Build host gate tests passed: {0}; skipped: {1}" -f $script:Passed, $script:Skipped)
