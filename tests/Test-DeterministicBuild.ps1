[CmdletBinding()]
param(
    [string]$ToolchainRoot = 'C:\Program Files\Microsoft Visual Studio\18\Community',
    [string]$ProgramFilesX86 = ${env:ProgramFiles(x86)}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
$source = Join-Path $repoRoot 'src\NativeHostLauncher.cs'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'Common NativeHostLauncher.cs is not present; deterministic release test cannot run yet.'
}

$testRoot = Join-Path $repoRoot ('.test-output\deterministic-' + [Guid]::NewGuid().ToString('N'))
$outA = Join-Path $testRoot 'release-output-a'
$outB = Join-Path $testRoot 'release-output-b-with-a-different-path'
try {
    $a = & (Join-Path $repoRoot 'Build-UnsignedRelease.ps1') `
        -Version '0.0.0-test' `
        -OutputDirectory $outA `
        -ToolchainRoot $ToolchainRoot `
        -ProgramFilesX86 $ProgramFilesX86
    $b = & (Join-Path $repoRoot 'Build-UnsignedRelease.ps1') `
        -Version '0.0.0-test' `
        -OutputDirectory $outB `
        -ToolchainRoot $ToolchainRoot `
        -ProgramFilesX86 $ProgramFilesX86

    if ($a.NativeHostSha256 -cne $b.NativeHostSha256) {
        throw 'Native Host SHA-256 differs across release builds.'
    }
    if ($a.ArchiveSha256 -cne $b.ArchiveSha256) {
        throw 'Unsigned ZIP SHA-256 differs across release builds.'
    }
    if ((Get-AuthenticodeSignature -LiteralPath (
        Join-Path $a.Package 'NativeHost\TaipowerAMINativeHostV2.exe'
    )).Status -ne [Management.Automation.SignatureStatus]::NotSigned) {
        throw 'Public Native Host unexpectedly contains an Authenticode signature.'
    }
    Write-Host 'Deterministic unsigned release tests passed: 3'
    Write-Host ('Native Host SHA-256: ' + $a.NativeHostSha256)
    Write-Host ('Archive SHA-256: ' + $a.ArchiveSha256)
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
