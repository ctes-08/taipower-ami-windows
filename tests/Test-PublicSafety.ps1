[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
Import-Module (Join-Path $repoRoot 'PublicCommon.psm1') -Force
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
    $script:Passed++
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw ('ASSERTION FAILED: ' + $Message + "`nExpected: $Expected`nActual: $Actual")
    }
    $script:Passed++
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action; throw ('ASSERTION FAILED: ' + $Message) } catch {
        if ($_.Exception.Message.StartsWith('ASSERTION FAILED:', [StringComparison]::Ordinal)) { throw }
    }
    $script:Passed++
}

$constants = Get-TaipowerAMIPublicConstants
Assert-Equal $constants.ExtensionId 'ajnbiemabobkigpbnfmoekolceigkica' 'extension ID is fixed'
Assert-Equal $constants.HostName 'tw.taipower_ami.native_host_v2' 'Native Messaging host name is fixed'
Assert-Equal $constants.AllowedOrigin 'chrome-extension://ajnbiemabobkigpbnfmoekolceigkica/' 'allowed origin is exact'
Assert-Equal $constants.ConfigRegistrySubKey 'Software\TaipowerAMI' 'configuration key is fixed'
Assert-Equal $constants.ConfigRegistryValue 'CredentialDestination' 'configuration value is fixed'
Assert-Equal `
    $constants.NativeRegistrationSubKey `
    'Software\Google\Chrome\NativeMessagingHosts\tw.taipower_ami.native_host_v2' `
    'Native Messaging registration key is fixed'

foreach ($probe in @(
    '.build/probe.bin',
    '.test-output/probe.bin',
    '.audit-output/probe.zip',
    'artifacts/probe.zip'
)) {
    & git -C $repoRoot check-ignore --quiet -- $probe
    $isIgnored = ($LASTEXITCODE -eq 0)
    Assert-True $isIgnored ('generated output is ignored by Git: ' + $probe)
}

$testRoot = Join-Path $repoRoot ('.test-output\public-safety-' + [Guid]::NewGuid().ToString('N'))
$realParent = Join-Path $testRoot 'real'
[IO.Directory]::CreateDirectory($realParent) | Out-Null
try {
    $good = Join-Path $realParent 'credentials.json'
    Assert-Equal `
        (Resolve-TaipowerAMICredentialDestination -Path $good -RequireParent) `
        ([IO.Path]::GetFullPath($good)) `
        'valid absolute local destination is normalized'
    Assert-Throws { Resolve-TaipowerAMICredentialDestination -Path '.\credentials.json' } 'relative destination is rejected'
    Assert-Throws { Resolve-TaipowerAMICredentialDestination -Path 'C:credentials.json' } 'drive-relative destination is rejected'
    Assert-Throws { Resolve-TaipowerAMICredentialDestination -Path '%TEMP%\credentials.json' } 'environment expansion is rejected'
    Assert-Throws { Resolve-TaipowerAMICredentialDestination -Path '\\?\C:\safe\credentials.json' } 'extended path is rejected'
    Assert-Throws { Resolve-TaipowerAMICredentialDestination -Path '\\.\C:\safe\credentials.json' } 'device path is rejected'
    Assert-Throws { Resolve-TaipowerAMICredentialDestination -Path (Join-Path $realParent 'credential.json') } 'wrong filename is rejected'
    Assert-Throws { Resolve-TaipowerAMICredentialDestination -Path ($good + ':alternate') } 'alternate data stream destination is rejected'
    Assert-Throws {
        Resolve-TaipowerAMICredentialDestination `
            -Path (Join-Path $testRoot 'missing\credentials.json') `
            -RequireParent
    } 'unavailable parent is rejected'

    $junction = Join-Path $testRoot 'junction'
    try {
        New-Item -ItemType Junction -Path $junction -Target $realParent -ErrorAction Stop | Out-Null
        Assert-Throws {
            Resolve-TaipowerAMICredentialDestination `
                -Path (Join-Path $junction 'credentials.json') `
                -RequireParent
        } 'reparse destination ancestry is rejected'
    } catch {
        if ($_.Exception.Message.StartsWith('ASSERTION FAILED:', [StringComparison]::Ordinal)) { throw }
        Write-Warning 'Junction creation unavailable; reparse runtime assertion skipped on this host.'
    }

    $extension = Test-TaipowerAMIExtensionBundle -ExtensionRoot (Join-Path $repoRoot 'chrome_extension')
    Assert-Equal $extension.Files.Count 5 'extension exact required file set is present'

    $manifestExe = Join-Path $realParent 'TaipowerAMINativeHostV2.exe'
    $manifestPath = Join-Path $realParent 'native_host_manifest.json'
    $manifest = New-TaipowerAMINativeManifest -ExecutablePath $manifestExe
    Write-TaipowerAMIUtf8NoBom `
        -LiteralPath $manifestPath `
        -Content (($manifest | ConvertTo-Json -Depth 5) + "`n")
    $validatedManifest = Test-TaipowerAMINativeManifest `
        -ManifestPath $manifestPath `
        -ExpectedExecutablePath $manifestExe
    Assert-Equal $validatedManifest.name $constants.HostName 'generated manifest preserves the fixed host name'
    Assert-Equal @($validatedManifest.allowed_origins).Count 1 'generated manifest has exactly one allowed origin'
    Assert-Equal $validatedManifest.allowed_origins[0] $constants.AllowedOrigin 'generated manifest preserves the fixed extension origin'
    Assert-Equal $validatedManifest.path $manifestExe 'generated manifest uses the exact absolute executable path'

    foreach ($path in Get-ChildItem -LiteralPath $repoRoot -File -Recurse |
        Where-Object { $_.FullName -notmatch '\\.git\\|\\.build\\|\\.test-output\\|\\.audit-output\\|\\artifacts\\' }) {
        $bytes = [IO.File]::ReadAllBytes($path.FullName)
        if ($bytes.Length -ge 3) {
            Assert-True `
                (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) `
                ('UTF-8 text file has no BOM: ' + $path.FullName)
        }
    }

    foreach ($scriptName in @(
        'Build-UnsignedRelease.ps1',
        'Install-UserScoped.ps1',
        'Uninstall-UserScoped.ps1',
        'PublicCommon.psm1',
        'PublicToolchain.psm1',
        'PublicBuild.psm1',
        'PublicArchive.psm1',
        'tests\Test-NativeHostDestination.ps1',
        'tests\Invoke-NativeHostDestinationChecks.ps1',
        'tests\Test-RegistryCas.ps1',
        'tests\Test-TransactionStructure.ps1',
        'tests\Test-SourceProvenance.ps1',
        'tests\Test-BuildHostGate.ps1',
        'tests\Test-PackageNeutrality.ps1',
        'tests\Prepare-CiToolchain.ps1'
    )) {
        $path = Join-Path $repoRoot $scriptName
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-Equal @($errors).Count 0 ($scriptName + ' parses without PowerShell syntax errors')
    }

    $installText = Get-Content -LiteralPath (Join-Path $repoRoot 'Install-UserScoped.ps1') -Raw -Encoding UTF8
    $uninstallText = Get-Content -LiteralPath (Join-Path $repoRoot 'Uninstall-UserScoped.ps1') -Raw -Encoding UTF8
    $buildText = Get-Content -LiteralPath (Join-Path $repoRoot 'Build-UnsignedRelease.ps1') -Raw -Encoding UTF8
    $ciBootstrapText = Get-Content `
        -LiteralPath (Join-Path $repoRoot 'tests\Prepare-CiToolchain.ps1') `
        -Raw -Encoding UTF8
    $workflowText = Get-Content `
        -LiteralPath (Join-Path $repoRoot '.github\workflows\validate.yml') `
        -Raw -Encoding UTF8
    $installationText = Get-Content `
        -LiteralPath (Join-Path $repoRoot 'docs\INSTALLATION.md') `
        -Raw -Encoding UTF8
    Assert-True ($buildText -match '\$PSVersionTable\.PSEdition\s+-ceq\s+''Desktop''') `
        'release builder requires Windows PowerShell Desktop edition'
    Assert-True ($buildText -match '\$PSVersionTable\.PSVersion\.Major\s+-eq\s+5' -and
        $buildText -match '\$PSVersionTable\.PSVersion\.Minor\s+-eq\s+1') `
        'release builder requires PowerShell version 5.1 exactly'
    Assert-True ($buildText -match '\[Environment\]::Is64BitProcess') `
        'release builder requires a 64-bit process'
    Assert-True ($buildText -match [regex]::Escape('docs\RELEASE_README.md') -and
        $buildText -match [regex]::Escape('docs\INSTALLATION.md') -and
        $buildText -match [regex]::Escape('SECURITY.md')) `
        'release builder packages the reviewed offline operator documents'
    Assert-True ($buildText -notmatch '(?i)LICENSE') `
        'release builder does not fabricate a license before a license decision'
    $installationPowerShellBlocks = @([regex]::Matches(
        $installationText,
        '(?ms)^```powershell\r?\n(.*?)^```'
    ))
    Assert-True ($installationPowerShellBlocks.Count -ge 4) `
        'installation guide carries complete verify, extract, install, and uninstall commands'
    foreach ($block in $installationPowerShellBlocks) {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseInput(
            $block.Groups[1].Value,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        Assert-Equal @($errors).Count 0 'installation PowerShell example parses without syntax errors'
    }
    Assert-True (
        $installationText.IndexOf('Get-FileHash', [StringComparison]::Ordinal) -ge 0 -and
        $installationText.IndexOf('Unblock-File', [StringComparison]::Ordinal) -gt
        $installationText.IndexOf('Get-FileHash', [StringComparison]::Ordinal)
    ) 'Mark-of-the-Web removal is documented only after SHA-256 verification'
    Assert-True ($installationText -notmatch '(?i)Unblock-File[^\r\n]*(?:-Recurse|Get-ChildItem)') `
        'installation guide never recursively unblocks files'
    Assert-True ($installationText -match [regex]::Escape('chrome://extensions') -and
        $installationText -match [regex]::Escape('Developer mode') -and
        $installationText -match [regex]::Escape('Load unpacked') -and
        $installationText -match [regex]::Escape('%LOCALAPPDATA%\TaipowerAMIV2\ChromeExtension')) `
        'installation guide documents the complete fixed-ID unpacked-extension workflow'
    Assert-True ($ciBootstrapText -notmatch '(?im)^\s*Remove-Item[^\r\n]*-Recurse\b') `
        'CI toolchain bootstrap never recursively deletes a caller-selected path'
    Assert-True ($ciBootstrapText -match '\[IO\.Path\]::DirectorySeparatorChar' -and
        $ciBootstrapText -match '\$workPath\s*\+\s*\$separator') `
        'CI WorkRoot descendant check uses the platform directory separator explicitly'
    Assert-True ($ciBootstrapText -match 'Get-AuthenticodeSignature' -and
        $ciBootstrapText -match 'O=Microsoft Corporation') `
        'CI bootstrap verifies the pinned Visual Studio Microsoft signature'
    Assert-True ($ciBootstrapText -match '0DF3A4470B1A8568DEC1C012F9DEFC72D7185F40EAA26ABEADF023C1D30275FB' -and
        $ciBootstrapText -match 'FFA0A5570A39F911399164D0581FFDDEF99B5E3DFBAA5F220E5CE22969BCF57C') `
        'CI bootstrap pins both downloaded inputs by SHA-256'
    $workflowUses = @([regex]::Matches($workflowText, '(?m)^\s*uses:\s*[^@\s]+@([^\s#]+)') |
        ForEach-Object { $_.Groups[1].Value })
    Assert-True ($workflowUses.Count -ge 1 -and
        @($workflowUses | Where-Object { $_ -cnotmatch '^[0-9a-f]{40}$' }).Count -eq 0) `
        'CI workflow pins every external action to a full commit hash'
    Assert-True ($workflowText -notmatch 'actions/upload-artifact') `
        'pull-request CI never uploads release artifacts'
    $hostGateIndex = $buildText.IndexOf('$isSupportedBuildHost', [StringComparison]::Ordinal)
    $firstImportIndex = $buildText.IndexOf('Import-Module', [StringComparison]::Ordinal)
    Assert-True ($hostGateIndex -ge 0 -and $firstImportIndex -gt $hostGateIndex) `
        'release build host gate runs before module import and staging setup'
    Assert-True ($installText -match 'Invoke-TaipowerAMIRegistryGuardedUpdate64') 'installer uses shared Registry64 guarded update'
    Assert-True ($uninstallText -match 'Invoke-TaipowerAMIRegistryGuardedUpdate64') 'uninstaller uses shared Registry64 guarded update'
    Assert-True ($installText -notmatch 'Registry32') 'installer never selects Registry32'
    Assert-True ($uninstallText -notmatch 'Registry32') 'uninstaller never selects Registry32'
    Assert-True ($uninstallText -notmatch 'credentials\.json.*Remove-Item') 'uninstaller never deletes handed-off credentials'

    $commonText = Get-Content -LiteralPath (Join-Path $repoRoot 'PublicCommon.psm1') -Raw -Encoding UTF8
    Assert-True ($commonText -match 'RegistryView\]::Registry64') 'shared registry implementation fixes HKCU to Registry64'
    Assert-True ($commonText -match [regex]::Escape('Local\TaipowerAMI.UserInstall.')) `
        'install and uninstall use the neutral current-user mutex namespace'
    Assert-True ($installText -match 'Invoke-TaipowerAMIWithUserInstallMutex' -and
        $uninstallText -match 'Invoke-TaipowerAMIWithUserInstallMutex') `
        'install and uninstall share the current-user mutex wrapper'
    Assert-True ($commonText -match 'DriveType\]::Network') 'installer rejects mapped network drives in favor of native UNC'

    $allPublicParts = @(Get-ChildItem -LiteralPath $repoRoot -File -Recurse |
        Where-Object { $_.FullName -notmatch '\\.git\\|\\.build\\|\\.test-output\\|\\.audit-output\\|\\artifacts\\' } |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 })
    $allPublicText = $allPublicParts -join "`n"
    $formerDomainMarker = 'si' + '73'
    $formerOrganizationMarker = 'CT' + 'ES'
    Assert-True ($allPublicText.IndexOf($formerDomainMarker, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        'no former private domain marker is embedded'
    Assert-True ($allPublicText.IndexOf($formerOrganizationMarker, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        'no former private organization marker is embedded'
    Assert-True ($allPublicText -notmatch '192\.168\.[0-9]+\.[0-9]+') 'no household IPv4 address is embedded'
    Assert-True ($allPublicText -notmatch '\\\\192\.168\.') 'no household UNC path is embedded'
    Assert-True ($allPublicText -notmatch '(?i)\b[A-Z]:\\Users\\') 'no private Windows user profile path is embedded'
    $emailMatches = @([regex]::Matches(
        $allPublicText,
        '(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b'
    ) | ForEach-Object { $_.Value })
    Assert-True ($emailMatches.Count -eq 0) 'no email address is embedded'
    Assert-True ($allPublicText -notmatch '(?i)(?:thumbprint|signer)[^\r\n]{0,80}\b[A-F0-9]{40,64}\b') `
        'no signer thumbprint is embedded'
    Assert-True ($allPublicText -notmatch '(?i)\bBearer\s+[A-Z0-9._~+\-/=]{16,}') `
        'no bearer token is embedded'
    Assert-True ($allPublicText -notmatch '(?i)\beyJ[A-Z0-9_-]{12,}\.[A-Z0-9_-]{8,}\.[A-Z0-9_-]{8,}\b') `
        'no JWT-like token is embedded'
    Assert-True ($allPublicText -notmatch (
        '(?i)["'']?(?:session|enkey|token|password|secret)["'']?\s*[:=]\s*' +
        '["''](?!<|false\b|null\b)[A-Z0-9._~+\-/=]{8,}["'']'
    )) 'no literal credential value is embedded'
    Assert-True ($allPublicText -notmatch 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY') 'no private key is embedded'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host ("Public safety tests passed: {0}" -f $script:Passed)
