[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\VS\TaipowerAMI-18.5.0',
    [string]$WorkRoot = (Join-Path $env:RUNNER_TEMP 'taipower-ami-toolchain')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($PSVersionTable.PSEdition -cne 'Desktop' -or
    $PSVersionTable.PSVersion.Major -ne 5 -or
    $PSVersionTable.PSVersion.Minor -ne 1 -or
    -not [Environment]::Is64BitProcess) {
    throw 'CI toolchain preparation requires 64-bit Windows PowerShell 5.1 Desktop.'
}
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'RUNNER_TEMP is required; this bootstrap is only for an ephemeral CI runner.'
}

function Resolve-CiLocalAbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Path -cnotmatch '^[A-Za-z]:\\' -or
        $Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw ($Name + ' must be an absolute local DOS path.')
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Equals([IO.Path]::GetPathRoot($full), [StringComparison]::OrdinalIgnoreCase)) {
        throw ($Name + ' must not be a volume root.')
    }
    return $full.TrimEnd('\\')
}

function Assert-NoReparseBelowBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Boundary
    )

    $current = $Path.TrimEnd('\\')
    $stop = $Boundary.TrimEnd('\\')
    while (-not $current.Equals($stop, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('CI path ancestry contains a reparse point: ' + $current)
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw 'CI path escaped its reviewed boundary.'
        }
        $current = $parent.FullName.TrimEnd('\\')
    }
}

function Get-PinnedDownload {
    param(
        [Parameter(Mandatory = $true)][uri]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9A-F]{64}$')]
        [string]$Sha256
    )

    if (Test-Path -LiteralPath $Destination) {
        throw ('Pinned download destination already exists: ' + $Destination)
    }
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($actual -cne $Sha256) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw ('Pinned download SHA-256 mismatch for ' + $Uri.AbsoluteUri)
    }
}

$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
$installPath = Resolve-CiLocalAbsolutePath -Path $InstallRoot -Name 'InstallRoot'
$runnerTemp = Resolve-CiLocalAbsolutePath -Path $env:RUNNER_TEMP -Name 'RUNNER_TEMP'
$workPath = Resolve-CiLocalAbsolutePath -Path $WorkRoot -Name 'WorkRoot'
$separator = [IO.Path]::DirectorySeparatorChar
$runnerPrefix = $runnerTemp + $separator
if ($workPath.Equals($runnerTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not (($workPath + $separator).StartsWith($runnerPrefix, [StringComparison]::OrdinalIgnoreCase))) {
    throw 'WorkRoot must be a strict descendant of RUNNER_TEMP.'
}

$runnerTempItem = Get-Item -LiteralPath $runnerTemp -Force
if (($runnerTempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'RUNNER_TEMP must not be a reparse point.'
}
Assert-NoReparseBelowBoundary -Path $workPath -Boundary $runnerTemp
if (Test-Path -LiteralPath $workPath) {
    throw 'WorkRoot must not pre-exist on the fresh CI runner.'
}
if (Test-Path -LiteralPath $installPath) {
    throw 'InstallRoot must not pre-exist on the fresh CI runner.'
}
$installParent = [IO.Path]::GetDirectoryName($installPath)
if (Test-Path -LiteralPath $installParent) {
    $installParentItem = Get-Item -LiteralPath $installParent -Force
    if (($installParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'InstallRoot parent must not be a reparse point.'
    }
}
[IO.Directory]::CreateDirectory($workPath) | Out-Null

$bootstrapper = Join-Path $workPath 'vs_BuildTools.exe'
$referencePackage = Join-Path $workPath 'Microsoft.NETFramework.ReferenceAssemblies.net472.1.0.3.nupkg'
$bootstrapperUri = [uri]('https://download.visualstudio.microsoft.com/download/pr/' +
    '7b660e19-415f-4c6c-bc8a-6a0b524cc688/' +
    '0df3a4470b1a8568dec1c012f9defc72d7185f40eaa26abeadf023c1d30275fb/' +
    'vs_BuildTools.exe')
$referencePackageUri = [uri](
    'https://api.nuget.org/v3-flatcontainer/' +
    'microsoft.netframework.referenceassemblies.net472/1.0.3/' +
    'microsoft.netframework.referenceassemblies.net472.1.0.3.nupkg'
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Get-PinnedDownload `
    -Uri $bootstrapperUri `
    -Destination $bootstrapper `
    -Sha256 '0DF3A4470B1A8568DEC1C012F9DEFC72D7185F40EAA26ABEADF023C1D30275FB'
Get-PinnedDownload `
    -Uri $referencePackageUri `
    -Destination $referencePackage `
    -Sha256 'FFA0A5570A39F911399164D0581FFDDEF99B5E3DFBAA5F220E5CE22969BCF57C'

$bootstrapperSignature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
if ($bootstrapperSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
    $null -eq $bootstrapperSignature.SignerCertificate -or
    $bootstrapperSignature.SignerCertificate.Subject -notmatch
        '(?i)(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
    throw 'Pinned Visual Studio bootstrapper does not have a valid Microsoft Authenticode identity.'
}

$arguments = @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--installPath', ('"' + $installPath + '"'),
    '--add', 'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools',
    '--add', 'Microsoft.Component.MSBuild',
    '--add', 'Microsoft.VisualStudio.Component.Roslyn.Compiler'
) -join ' '
$installer = Start-Process `
    -FilePath $bootstrapper `
    -ArgumentList $arguments `
    -Wait `
    -PassThru `
    -WindowStyle Hidden
if (@(0, 3010) -notcontains $installer.ExitCode) {
    throw ('Pinned Visual Studio Build Tools installation failed with exit code ' + $installer.ExitCode)
}
if (-not (Test-Path -LiteralPath $installPath -PathType Container) -or
    ((Get-Item -LiteralPath $installPath -Force).Attributes -band
        [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Pinned Visual Studio Build Tools produced an invalid installation root.'
}

$extractRoot = Join-Path $workPath 'net472-package'
[IO.Directory]::CreateDirectory($extractRoot) | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($referencePackage, $extractRoot)
$referenceSource = Join-Path $extractRoot 'build\.NETFramework\v4.7.2'
$programFilesX86 = Join-Path $workPath 'program-files-x86'
$referenceDestination = Join-Path $programFilesX86 (
    'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2'
)
[IO.Directory]::CreateDirectory($referenceDestination) | Out-Null
foreach ($name in @('mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Web.Extensions.dll')) {
    $source = Join-Path $referenceSource $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw ('Pinned net472 package is missing required reference: ' + $name)
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $referenceDestination $name)
}

Import-Module (Join-Path $repoRoot 'PublicToolchain.psm1') -Force
$validated = Resolve-TaipowerAMIPinnedToolchain `
    -LockPath (Join-Path $repoRoot 'NativeHostToolchain.lock.json') `
    -ToolchainRoot $installPath `
    -ProgramFilesX86 $programFilesX86

[pscustomobject]@{
    ToolchainRoot = $installPath
    ProgramFilesX86 = $programFilesX86
    ToolchainId = $validated.Id
    LockSha256 = $validated.LockSha256
}
