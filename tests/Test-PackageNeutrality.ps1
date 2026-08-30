[CmdletBinding()]
param(
    [string]$ToolchainRoot = 'C:\Program Files\Microsoft Visual Studio\18\Community',
    [string]$ProgramFilesX86 = ${env:ProgramFiles(x86)}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
Import-Module (Join-Path $repoRoot 'PublicCommon.psm1') -Force
$testRoot = Join-Path $repoRoot ('.test-output\package-neutrality-' + [Guid]::NewGuid().ToString('N'))
$releaseOutput = Join-Path $testRoot 'release'
$script:Passed = 0
$reviewedCompatibilitySha256 = '329A81522783A07B08AA2D32292A5623B795C71EC7FC73933AD3FFA2507AEB30'

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
    Assert-True ([string]$release.NativeHostSha256 -ceq $reviewedCompatibilitySha256) `
        '2.0.1 Native Host matches the reviewed cross-channel unsigned binary'
    $validatedPackage = Test-TaipowerAMIUnsignedPackage -PackageRoot $release.Package
    Assert-True ([string]$validatedPackage.Root -ceq [string]$release.Package) `
        'installer package validator accepts the complete reviewed release'

    $releaseDocuments = @(
        [pscustomobject]@{
            Source = 'docs\RELEASE_README.md'
            Packaged = 'README.md'
        },
        [pscustomobject]@{
            Source = 'docs\INSTALLATION.md'
            Packaged = 'INSTALLATION.md'
        },
        [pscustomobject]@{
            Source = 'SECURITY.md'
            Packaged = 'SECURITY.md'
        },
        [pscustomobject]@{
            Source = 'LICENSE'
            Packaged = 'LICENSE'
        }
    )
    $sumLines = @(Get-Content -LiteralPath (Join-Path $release.Package 'SHA256SUMS') -Encoding UTF8)
    foreach ($document in $releaseDocuments) {
        $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $repoRoot $document.Source))
        $packagedPath = Join-Path $release.Package $document.Packaged
        Assert-True (Test-Path -LiteralPath $packagedPath -PathType Leaf) `
            ('release contains ' + $document.Packaged)
        Assert-True ([Linq.Enumerable]::SequenceEqual(
            [byte[]]$sourceBytes,
            [byte[]][IO.File]::ReadAllBytes($packagedPath)
        )) ('packaged document is byte-identical to reviewed source: ' + $document.Packaged)
        Assert-True (@($sumLines | Where-Object {
            $_ -cmatch ('^[0-9A-F]{64}  ' + [regex]::Escape($document.Packaged) + '$')
        }).Count -eq 1) ('SHA256SUMS covers ' + $document.Packaged)
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $release.Package 'LICENSE') -PathType Leaf) `
        'package contains the selected Apache License 2.0 text'

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
    $packageContentWithoutApprovedOwner = $packageContent.Replace('ctes-08', '')

    Assert-True ($packageContent.IndexOf($formerDomainMarker, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        'package contains no former private domain marker'
    Assert-True ($packageContentWithoutApprovedOwner.IndexOf(
        $formerOrganizationMarker,
        [StringComparison]::OrdinalIgnoreCase
    ) -lt 0) 'package contains no former private organization marker beyond the approved GitHub owner'
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

Write-Host ('Native Host compatibility SHA-256: ' + $reviewedCompatibilitySha256)
Write-Host ("Package neutrality tests passed: {0}" -f $script:Passed)
