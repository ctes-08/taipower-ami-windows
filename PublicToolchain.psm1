Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PublicCommon.psm1') -Force -Scope Local
function Read-TaipowerAMIToolchainLock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $lockPath = Resolve-TaipowerAMIAbsoluteLocalPath -Path $LiteralPath
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rootProperties = @($lock.PSObject.Properties.Name | Sort-Object)
    $expectedRootProperties = @(
        'compiler_relative_path', 'files', 'kind', 'reference_root_relative_path',
        'schema_version', 'target_framework_moniker', 'toolchain_id'
    ) | Sort-Object
    if ([int]$lock.schema_version -ne 1 -or
        [string]$lock.kind -ne 'pinned_visual_studio_roslyn' -or
        [string]$lock.toolchain_id -cne 'vs18.5.4-roslyn5.5.0-netfx472-x64' -or
        [string]$lock.compiler_relative_path -cne 'MSBuild\Current\Bin\Roslyn\csc.exe' -or
        [string]$lock.target_framework_moniker -cne '.NETFramework,Version=v4.7.2' -or
        [string]$lock.reference_root_relative_path -cne 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2' -or
        ($rootProperties -join "`n") -cne ($expectedRootProperties -join "`n")) {
        throw 'Unsupported or incomplete Native Host toolchain lock.'
    }

    $approved = [ordered]@{
        msbuild = @('toolchain_root', 'MSBuild\Current\Bin\MSBuild.exe')
        roslyn_csc = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\csc.exe')
        roslyn_csc_config = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\csc.exe.config')
        roslyn_codeanalysis = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\Microsoft.CodeAnalysis.dll')
        roslyn_csharp = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\Microsoft.CodeAnalysis.CSharp.dll')
        roslyn_system_buffers = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\System.Buffers.dll')
        roslyn_system_collections_immutable = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\System.Collections.Immutable.dll')
        roslyn_system_memory = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\System.Memory.dll')
        roslyn_system_numerics_vectors = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\System.Numerics.Vectors.dll')
        roslyn_system_reflection_metadata = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\System.Reflection.Metadata.dll')
        roslyn_system_runtime_unsafe = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\System.Runtime.CompilerServices.Unsafe.dll')
        roslyn_system_text_codepages = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\System.Text.Encoding.CodePages.dll')
        roslyn_system_threading_tasks_extensions = @('toolchain_root', 'MSBuild\Current\Bin\Roslyn\System.Threading.Tasks.Extensions.dll')
        netfx_mscorlib = @('program_files_x86', 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2\mscorlib.dll')
        netfx_system = @('program_files_x86', 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2\System.dll')
        netfx_system_core = @('program_files_x86', 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2\System.Core.dll')
        netfx_system_web_extensions = @('program_files_x86', 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2\System.Web.Extensions.dll')
    }
    $records = @($lock.files)
    if ($records.Count -ne $approved.Count) {
        throw 'Native Host toolchain lock contains an unexpected file-record count.'
    }
    $seen = @{}
    $expectedRecordProperties = @('base', 'bytes', 'file_version', 'path', 'product_version', 'role', 'sha256') | Sort-Object
    foreach ($record in $records) {
        $properties = @($record.PSObject.Properties.Name | Sort-Object)
        $role = [string]$record.role
        if (($properties -join "`n") -cne ($expectedRecordProperties -join "`n") -or
            -not $approved.Contains($role) -or $seen.ContainsKey($role) -or
            [string]$record.base -cne [string]$approved[$role][0] -or
            [string]$record.path -cne [string]$approved[$role][1] -or
            [long]$record.bytes -le 0 -or [string]$record.sha256 -cnotmatch '^[0-9A-F]{64}$') {
            throw ('Native Host toolchain lock contains an invalid record: ' + $role)
        }
        $seen[$role] = $true
    }
    return $lock
}

function Resolve-TaipowerAMIToolchainFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$ToolchainRoot,
        [Parameter(Mandatory = $true)][string]$ProgramFilesX86
    )

    $base = switch ([string]$Entry.base) {
        'toolchain_root' { $ToolchainRoot }
        'program_files_x86' { $ProgramFilesX86 }
        default { throw 'Toolchain lock contains an unsupported base.' }
    }
    $candidate = Resolve-TaipowerAMIAbsoluteLocalPath -Path (Join-Path $base ([string]$Entry.path))
    $file = Get-Item -LiteralPath $candidate -Force
    if ($file.Length -ne [long]$Entry.bytes -or
        (Get-TaipowerAMIFileHashHex -LiteralPath $candidate) -cne ([string]$Entry.sha256).ToUpperInvariant()) {
        throw ('Pinned toolchain file validation failed for role: ' + [string]$Entry.role)
    }
    return $candidate
}

function Resolve-TaipowerAMIPinnedToolchain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][string]$ToolchainRoot,
        [Parameter(Mandatory = $true)][string]$ProgramFilesX86
    )

    $root = Resolve-TaipowerAMIAbsoluteLocalPath -Path $ToolchainRoot
    $pf86 = Resolve-TaipowerAMIAbsoluteLocalPath -Path $ProgramFilesX86
    $lock = Read-TaipowerAMIToolchainLock -LiteralPath $LockPath
    $resolved = @{}
    foreach ($entry in $lock.files) {
        $resolved[[string]$entry.role] = Resolve-TaipowerAMIToolchainFile `
            -Entry $entry -ToolchainRoot $root -ProgramFilesX86 $pf86
    }

    foreach ($required in @(
        'roslyn_csc', 'netfx_mscorlib', 'netfx_system',
        'netfx_system_core', 'netfx_system_web_extensions'
    )) {
        if (-not $resolved.ContainsKey($required)) {
            throw ('Pinned toolchain lock is missing role: ' + $required)
        }
    }

    [pscustomobject]@{
        Id = [string]$lock.toolchain_id
        Lock = $lock
        Files = $resolved
        LockSha256 = Get-TaipowerAMIFileHashHex -LiteralPath $LockPath
    }
}
