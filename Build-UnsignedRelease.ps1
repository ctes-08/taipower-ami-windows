[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'artifacts'),

    [string]$ToolchainRoot = 'C:\Program Files\Microsoft Visual Studio\18\Community',

    [string]$ProgramFilesX86 = ${env:ProgramFiles(x86)}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isSupportedBuildHost = (
    $PSVersionTable.PSEdition -ceq 'Desktop' -and
    $PSVersionTable.PSVersion.Major -eq 5 -and
    $PSVersionTable.PSVersion.Minor -eq 1 -and
    [Environment]::Is64BitProcess
)
if (-not $isSupportedBuildHost) {
    throw (
        'Official public release builds require 64-bit Windows PowerShell 5.1 Desktop ' +
        '(powershell.exe). PowerShell 7 (pwsh.exe) and 32-bit Windows PowerShell are not supported.'
    )
}

Import-Module (Join-Path $PSScriptRoot 'PublicCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PublicToolchain.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PublicBuild.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PublicArchive.psm1') -Force

$sourceRoot = Resolve-TaipowerAMIAbsoluteLocalPath -Path $PSScriptRoot
$outputRoot = Resolve-TaipowerAMIAbsoluteLocalPath -Path $OutputDirectory -AllowMissing
$sourcePath = Join-Path $sourceRoot 'src\NativeHostLauncher.cs'
$lockPath = Join-Path $sourceRoot 'NativeHostToolchain.lock.json'
$extensionRoot = Join-Path $sourceRoot 'chrome_extension'
$releaseDocuments = @(
    [pscustomobject]@{
        Source = 'docs\RELEASE_README.md'
        Destination = 'README.md'
    },
    [pscustomobject]@{
        Source = 'docs\INSTALLATION.md'
        Destination = 'INSTALLATION.md'
    },
    [pscustomobject]@{
        Source = 'SECURITY.md'
        Destination = 'SECURITY.md'
    },
    [pscustomobject]@{
        Source = 'PRIVACY.md'
        Destination = 'PRIVACY.md'
    },
    [pscustomobject]@{
        Source = 'CODE_SIGNING_POLICY.md'
        Destination = 'CODE_SIGNING_POLICY.md'
    },
    [pscustomobject]@{
        Source = 'LICENSE'
        Destination = 'LICENSE'
    }
)

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw 'The reviewed common NativeHostLauncher.cs has not been added to this repository.'
}
foreach ($document in $releaseDocuments) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $document.Source) -PathType Leaf)) {
        throw ('Required release document is missing: ' + $document.Source)
    }
}
$toolchain = Resolve-TaipowerAMIPinnedToolchain `
    -LockPath $lockPath `
    -ToolchainRoot $ToolchainRoot `
    -ProgramFilesX86 $ProgramFilesX86
$extension = Test-TaipowerAMIExtensionBundle -ExtensionRoot $extensionRoot

$runId = [Guid]::NewGuid().ToString('N')
$runRoot = Join-Path $sourceRoot ('.build\' + $runId)
$stagedSourceA = Join-Path $runRoot 'different-absolute-path-a\source\NativeHostLauncher.cs'
$stagedSourceB = Join-Path $runRoot 'another-absolute-path-b\source\NativeHostLauncher.cs'
$compileA = Join-Path $runRoot 'different-absolute-path-a\output\TaipowerAMINativeHostV2.exe'
$compileB = Join-Path $runRoot 'another-absolute-path-b\output\TaipowerAMINativeHostV2.exe'

try {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stagedSourceA)) | Out-Null
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stagedSourceB)) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $stagedSourceA
    Copy-Item -LiteralPath $sourcePath -Destination $stagedSourceB
    $first = Invoke-TaipowerAMIDeterministicCompile `
        -SourcePath $stagedSourceA -OutputPath $compileA -Toolchain $toolchain -Version $Version
    $second = Invoke-TaipowerAMIDeterministicCompile `
        -SourcePath $stagedSourceB -OutputPath $compileB -Toolchain $toolchain -Version $Version
    if ($first.Sha256 -cne $second.Sha256 -or
        -not [Linq.Enumerable]::SequenceEqual(
            [byte[]][IO.File]::ReadAllBytes($compileA),
            [byte[]][IO.File]::ReadAllBytes($compileB)
        )) {
        throw 'Deterministic build gate failed: clean staging builds differ.'
    }
    $toolchainAfter = Resolve-TaipowerAMIPinnedToolchain `
        -LockPath $lockPath `
        -ToolchainRoot $ToolchainRoot `
        -ProgramFilesX86 $ProgramFilesX86
    if ($toolchainAfter.Id -cne $toolchain.Id -or
        $toolchainAfter.LockSha256 -cne $toolchain.LockSha256) {
        throw 'Pinned toolchain changed during compilation.'
    }

    $provenance = Get-TaipowerAMISourceProvenance -SourceRoot $sourceRoot

    $packageName = 'taipower-ami-windows-' + $Version + '-unsigned'
    $packageRoot = Join-Path $runRoot $packageName
    $nativeRoot = Join-Path $packageRoot 'NativeHost'
    $packageExtension = Join-Path $packageRoot 'ChromeExtension'
    $installerRoot = Join-Path $packageRoot 'Installer'
    [IO.Directory]::CreateDirectory($nativeRoot) | Out-Null
    [IO.Directory]::CreateDirectory($packageExtension) | Out-Null
    [IO.Directory]::CreateDirectory($installerRoot) | Out-Null

    Copy-Item -LiteralPath $compileA -Destination (Join-Path $nativeRoot 'TaipowerAMINativeHostV2.exe')
    foreach ($name in $extension.Files) {
        Copy-Item -LiteralPath (Join-Path $extension.Root $name) -Destination (Join-Path $packageExtension $name)
    }
    foreach ($name in @(
        'Install-UserScoped.ps1',
        'Uninstall-UserScoped.ps1',
        'PublicCommon.psm1'
    )) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $installerRoot $name)
    }
    foreach ($document in $releaseDocuments) {
        Copy-Item `
            -LiteralPath (Join-Path $sourceRoot $document.Source) `
            -Destination (Join-Path $packageRoot $document.Destination)
    }

    $manifestTemplate = New-TaipowerAMINativeManifest `
        -ExecutablePath 'C:\ABSOLUTE_PATH_SET_BY_INSTALLER\TaipowerAMINativeHostV2.exe'
    Write-TaipowerAMIUtf8NoBom `
        -LiteralPath (Join-Path $nativeRoot 'native_host_manifest.template.json') `
        -Content (($manifestTemplate | ConvertTo-Json -Depth 5) + "`n")

    $metadata = [ordered]@{
        schema_version = 1
        release_channel = 'public_unsigned'
        version = $Version
        source_commit = $provenance.Commit
        source_tree_state = $provenance.TreeState
        native_host_sha256 = $first.Sha256
        extension_id = (Get-TaipowerAMIPublicConstants).ExtensionId
        native_host_name = (Get-TaipowerAMIPublicConstants).HostName
        allowed_origins = @((Get-TaipowerAMIPublicConstants).AllowedOrigin)
        signed = $false
        signer = $null
        timestamp = $null
        toolchain = [ordered]@{
            id = $toolchain.Id
            lock_sha256 = $toolchain.LockSha256
        }
        reproducibility = [ordered]@{
            clean_staging_builds = 2
            identical_executable_bytes = $true
            path_mapping = '/_/obj,/_/src'
        }
    }
    Write-TaipowerAMIUtf8NoBom `
        -LiteralPath (Join-Path $packageRoot 'release_metadata.json') `
        -Content (($metadata | ConvertTo-Json -Depth 8) + "`n")

    $checksummedFiles = Get-ChildItem -LiteralPath $packageRoot -File -Recurse |
        Where-Object -Property Name -CNE -Value 'SHA256SUMS' |
        Sort-Object -Property FullName
    $sumLines = foreach ($file in $checksummedFiles) {
        $relative = $file.FullName.Substring($packageRoot.Length).TrimStart('\').Replace('\', '/')
        (Get-TaipowerAMIFileHashHex -LiteralPath $file.FullName) + '  ' + $relative
    }
    Write-TaipowerAMIUtf8NoBom `
        -LiteralPath (Join-Path $packageRoot 'SHA256SUMS') `
        -Content (($sumLines -join "`n") + "`n")

    [IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $finalPackage = Join-Path $outputRoot $packageName
    $finalZip = Join-Path $outputRoot ($packageName + '.zip')
    $finalSidecar = $finalZip + '.sha256'
    foreach ($path in @($finalPackage, $finalZip, $finalSidecar)) {
        if (Test-Path -LiteralPath $path) {
            throw ('Refusing to overwrite an existing release artifact: ' + $path)
        }
    }

    $zip = New-TaipowerAMIDeterministicZip -SourceDirectory $packageRoot -DestinationPath (Join-Path $runRoot ($packageName + '.zip'))
    Move-Item -LiteralPath $packageRoot -Destination $finalPackage
    Move-Item -LiteralPath $zip.Path -Destination $finalZip
    Write-TaipowerAMIUtf8NoBom `
        -LiteralPath $finalSidecar `
        -Content ($zip.Sha256 + '  ' + [IO.Path]::GetFileName($finalZip) + "`n")

    # A repository without a first commit makes `git rev-parse` return 1. That
    # is valid for an explicitly UNCOMMITTED public candidate, but PowerShell
    # would otherwise leak the stale native exit code to CI after a successful
    # build.
    $global:LASTEXITCODE = 0

    [pscustomobject]@{
        Package = $finalPackage
        Archive = $finalZip
        ArchiveSha256 = $zip.Sha256
        ArchiveSidecar = $finalSidecar
        NativeHostSha256 = $first.Sha256
        Signed = $false
        Toolchain = $toolchain.Id
    }
} finally {
    if (Test-Path -LiteralPath $runRoot) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force
    }
}
