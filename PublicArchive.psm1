Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PublicCommon.psm1') -Force -Scope Local
function New-TaipowerAMIDeterministicZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $source = Resolve-TaipowerAMIAbsoluteLocalPath -Path $SourceDirectory
    $destination = Resolve-TaipowerAMIAbsoluteLocalPath -Path $DestinationPath -AllowMissing
    $parent = [IO.Path]::GetDirectoryName($destination)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Force
    }

    $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $stream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false,
            [Text.UTF8Encoding]::new($false)
        )
        try {
            $files = Get-ChildItem -LiteralPath $source -File -Recurse |
                Sort-Object -Property FullName
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($source.Length).TrimStart('\').Replace('\', '/')
                $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $entryStream = $entry.Open()
                try {
                    $input = [IO.File]::OpenRead($file.FullName)
                    try { $input.CopyTo($entryStream) } finally { $input.Dispose() }
                } finally { $entryStream.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }

    [pscustomobject]@{
        Path = $destination
        Sha256 = Get-TaipowerAMIFileHashHex -LiteralPath $destination
    }
}
