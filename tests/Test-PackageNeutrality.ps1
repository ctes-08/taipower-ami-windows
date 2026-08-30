[CmdletBinding()]
param(
    [string]$ToolchainRoot = 'C:\Program Files\Microsoft Visual Studio\18\Community',
    [string]$ProgramFilesX86 = ${env:ProgramFiles(x86)}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
$testRoot = Join-Path $repoRoot ('.test-output\package-neutrality-' + [Guid]::NewGuid().ToString('N'))
$releaseOutput = Join-Path $testRoot 'release'
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
    $script:Passed++
}

try {
    $release = & (Join-Path $repoRoot 'Build-UnsignedRelease.ps1') `
        -Version '2.0.1' `
        -OutputDirectory $releaseOutput `
        -ToolchainRoot $ToolchainRoot `
        -ProgramFilesX86 $ProgramFilesX86

    $metadata = Get-Content `
        -LiteralPath (Join-Path $release.Package 'release_metadata.json') `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest = Get-Content `
        -LiteralPath (Join-Path $release.Package 'ChromeExtension\manifest.json') `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    $nativeExe = Join-Path $release.Package 'NativeHost\TaipowerAMINativeHostV2.exe'

    Assert-True ([string]$metadata.version -ceq '2.0.1') 'release metadata carries version 2.0.1'
    Assert-True ([string]$manifest.version -ceq '2.0.1') 'extension manifest carries version 2.0.1'
    Assert-True ((Get-Item -LiteralPath $nativeExe).VersionInfo.FileVersion -like '2.0.1.*') `
        'Native Host file version carries version 2.0.1'

    $representations = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $release.Package -File -Recurse) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $representations.Add([Text.Encoding]::ASCII.GetString($bytes))
        if (($bytes.Length % 2) -eq 0) {
            $representations.Add([Text.Encoding]::Unicode.GetString($bytes))
        }
    }
    $packageContent = $representations -join "`n"
    $formerDomainMarker = 'si' + '73'
    $formerOrganizationMarker = 'CT' + 'ES'

    Assert-True ($packageContent.IndexOf($formerDomainMarker, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        'package contains no former private domain marker'
    Assert-True ($packageContent.IndexOf($formerOrganizationMarker, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        'package contains no former private organization marker'
    Assert-True ($packageContent -notmatch '192\.168\.[0-9]+\.[0-9]+') `
        'package contains no household IPv4 address'
    Assert-True ($packageContent -notmatch '(?i)\b[A-Z]:\\Users\\') `
        'package contains no private Windows user profile path'
    Assert-True ($packageContent -notmatch '(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b') `
        'package contains no email address'
    Assert-True ($packageContent -notmatch '(?i)(?:thumbprint|signer)[^\r\n]{0,80}\b[A-F0-9]{40,64}\b') `
        'package contains no signer thumbprint'
    Assert-True ($packageContent -notmatch '(?i)\bBearer\s+[A-Z0-9._~+\-/=]{16,}') `
        'package contains no bearer token'
    Assert-True ($packageContent -notmatch '(?i)\beyJ[A-Z0-9_-]{12,}\.[A-Z0-9_-]{8,}\.[A-Z0-9_-]{8,}\b') `
        'package contains no JWT-like token'
    Assert-True ($packageContent -notmatch 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY') `
        'package contains no private key'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host ("Package neutrality tests passed: {0}" -f $script:Passed)
