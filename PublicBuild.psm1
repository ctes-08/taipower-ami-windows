Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PublicCommon.psm1') -Force -Scope Local

function Get-TaipowerAMISourceProvenance {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $root = Resolve-TaipowerAMIAbsoluteLocalPath -Path $SourceRoot
    $commit = 'UNCOMMITTED'
    $treeState = 'uncommitted'
    $head = @(& git -C $root rev-parse --verify --quiet HEAD 2>$null)
    $headExitCode = $LASTEXITCODE
    if ($headExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($head -join ''))) {
        $commit = ($head -join '').Trim()

        & git -C $root diff --quiet --ignore-submodules --
        $unstagedExitCode = $LASTEXITCODE
        if ($unstagedExitCode -notin @(0, 1)) {
            throw 'Unable to inspect unstaged Git changes for release provenance.'
        }

        & git -C $root diff --cached --quiet --ignore-submodules --
        $stagedExitCode = $LASTEXITCODE
        if ($stagedExitCode -notin @(0, 1)) {
            throw 'Unable to inspect staged Git changes for release provenance.'
        }

        $untracked = @(& git -C $root ls-files --others --exclude-standard)
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to inspect untracked Git files for release provenance.'
        }
        if ($unstagedExitCode -eq 0 -and $stagedExitCode -eq 0 -and $untracked.Count -eq 0) {
            $treeState = 'clean'
        }
    }

    $global:LASTEXITCODE = 0
    return [pscustomobject]@{
        Commit = $commit
        TreeState = $treeState
    }
}

function Invoke-TaipowerAMIDeterministicCompile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)]$Toolchain,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')]
        [string]$Version
    )

    $source = Resolve-TaipowerAMIAbsoluteLocalPath -Path $SourcePath
    $output = Resolve-TaipowerAMIAbsoluteLocalPath -Path $OutputPath -AllowMissing
    $outputParent = [IO.Path]::GetDirectoryName($output)
    [IO.Directory]::CreateDirectory($outputParent) | Out-Null

    $sourceDirectory = [IO.Path]::GetDirectoryName($source)
    foreach ($pathMapInput in @($sourceDirectory, $outputParent)) {
        if ($pathMapInput.Contains(',') -or $pathMapInput.Contains('=')) {
            throw 'Deterministic staging paths must not contain commas or equals signs.'
        }
    }
    $assemblyInfo = Join-Path $outputParent '.TaipowerAMI.AssemblyInfo.cs'
    if (Test-Path -LiteralPath $assemblyInfo) {
        throw 'Deterministic assembly metadata staging file already exists.'
    }
    $numericVersion = ($Version -split '-', 2)[0]
    $fourPartVersion = $numericVersion
    while (($fourPartVersion -split '\.').Count -lt 4) { $fourPartVersion += '.0' }
    $assemblyText = @(
        'using System.Reflection;',
        '[assembly: AssemblyTitle("Taipower AMI Native Host")]',
        '[assembly: AssemblyDescription("Native Messaging host for the Taipower AMI Windows Companion")]',
        '[assembly: AssemblyCompany("Taipower AMI contributors")]',
        '[assembly: AssemblyProduct("Taipower AMI Windows Companion")]',
        '[assembly: AssemblyCopyright("Copyright 2026 ctes-08 and contributors")]',
        ('[assembly: AssemblyVersion("' + $fourPartVersion + '")]'),
        ('[assembly: AssemblyFileVersion("' + $fourPartVersion + '")]'),
        ('[assembly: AssemblyInformationalVersion("' + $Version + '")]'),
        ('[assembly: AssemblyMetadata("TaipowerAMI.ToolchainId", "' + $Toolchain.Id + '")]'),
        ('[assembly: AssemblyMetadata("TaipowerAMI.ToolchainLockSha256", "' + $Toolchain.LockSha256 + '")]'),
        '[assembly: AssemblyMetadata("TaipowerAMI.Deterministic", "true")]'
    ) -join [Environment]::NewLine
    Write-TaipowerAMIUtf8NoBom `
        -LiteralPath $assemblyInfo `
        -Content ($assemblyText + [Environment]::NewLine)
    try {
        $virtualSource = '/_/src/NativeHostLauncher.cs'
        $arguments = @(
            '/nologo', '/noconfig', '/nostdlib+', '/deterministic+', '/optimize+',
            '/debug-', '/target:exe', '/platform:anycpu',
            '/langversion:7.3', '/warn:4', '/warnaserror+', '/utf8output',
            '/main:NativeHostLauncher',
            ('/pathmap:' + $outputParent + '=/_/obj,' + $sourceDirectory + '=/_/src'),
            ('/out:' + $output),
            $source,
            $assemblyInfo,
            ('/reference:' + $Toolchain.Files.netfx_mscorlib),
            ('/reference:' + $Toolchain.Files.netfx_system),
            ('/reference:' + $Toolchain.Files.netfx_system_core),
            ('/reference:' + $Toolchain.Files.netfx_system_web_extensions)
        )
        $outputText = & $Toolchain.Files.roslyn_csc @arguments 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
            $safe = ($outputText | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            throw ('Deterministic Native Host compilation failed.' + [Environment]::NewLine + $safe)
        }
        return [pscustomobject]@{
            Path = $output
            Sha256 = Get-TaipowerAMIFileHashHex -LiteralPath $output
            VirtualSource = $virtualSource
        }
    } finally {
        if (Test-Path -LiteralPath $assemblyInfo) {
            Remove-Item -LiteralPath $assemblyInfo -Force
        }
    }
}
