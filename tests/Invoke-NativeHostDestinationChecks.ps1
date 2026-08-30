[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [Parameter(Mandatory = $true)][string]$TestRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Skipped = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw ('ASSERTION FAILED: ' + $Message + "`nExpected: $Expected`nActual: $Actual")
    }
    $script:Passed++
}

function Invoke-PrivateStaticMethod {
    param(
        [Parameter(Mandatory = $true)][Type]$Type,
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$Arguments = @()
    )

    $flags = [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
    $method = $Type.GetMethod($Name, $flags)
    if ($null -eq $method) {
        throw ('Required private Native Host method was not found: ' + $Name)
    }
    try {
        return $method.Invoke($null, $Arguments)
    } catch [Reflection.TargetInvocationException] {
        if ($null -ne $_.Exception.InnerException) {
            throw $_.Exception.InnerException
        }
        throw
    }
}

function Assert-PrivateMethodThrowsSafe {
    param(
        [Parameter(Mandatory = $true)][Type]$Type,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$SensitiveText,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        Invoke-PrivateStaticMethod -Type $Type -Name $Name -Arguments $Arguments | Out-Null
        throw ('ASSERTION FAILED: ' + $Message)
    } catch {
        if ($_.Exception.Message.StartsWith('ASSERTION FAILED:', [StringComparison]::Ordinal)) {
            throw
        }
        if (-not [string]::IsNullOrEmpty($SensitiveText) -and
            $_.Exception.Message.IndexOf($SensitiveText, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw ('ASSERTION FAILED: rejected path leaked through the safe error: ' + $Message)
        }
    }
    $script:Passed++
}

$exe = [IO.Path]::GetFullPath($ExecutablePath)
$root = [IO.Path]::GetFullPath($TestRoot)
$realParent = Join-Path $root 'real-parent'
[IO.Directory]::CreateDirectory($realParent) | Out-Null

$assembly = [Reflection.Assembly]::LoadFile($exe)
$hostType = $assembly.GetType('NativeHostLauncher', $true, $false)

$localRoot = [IO.Path]::GetPathRoot([Environment]::SystemDirectory)
Assert-Equal `
    (Invoke-PrivateStaticMethod -Type $hostType -Name 'NormalizeFinalDirectoryPath' -Arguments @($localRoot)) `
    $localRoot `
    'local volume root remains a rooted path'
Assert-Equal `
    (Invoke-PrivateStaticMethod -Type $hostType -Name 'NormalizeFinalDirectoryPath' -Arguments @(('\\?\' + $localRoot))) `
    $localRoot `
    'extended local volume root normalizes without losing its separator'

$uncShareRoot = '\\server.invalid\share\'
Assert-Equal `
    ((Invoke-PrivateStaticMethod -Type $hostType -Name 'NormalizeFinalDirectoryPath' -Arguments @($uncShareRoot)).TrimEnd('\')) `
    $uncShareRoot.TrimEnd('\') `
    'UNC share root remains a rooted path without contacting the share'
Assert-Equal `
    ((Invoke-PrivateStaticMethod -Type $hostType -Name 'NormalizeFinalDirectoryPath' -Arguments @('\\?\UNC\server.invalid\share\')).TrimEnd('\')) `
    $uncShareRoot.TrimEnd('\') `
    'extended UNC share root normalizes without losing its separator'

$destination = Join-Path $realParent 'credentials.json'
Assert-Equal `
    (Invoke-PrivateStaticMethod `
        -Type $hostType `
        -Name 'ValidateCredentialDestinationDirectory' `
        -Arguments @([string]$destination)) `
    ([IO.Path]::GetFullPath($realParent).TrimEnd('\', '/')) `
    'existing local parent passes runtime identity validation'

$missing = Join-Path $root 'missing-parent\credentials.json'
Assert-PrivateMethodThrowsSafe `
    -Type $hostType `
    -Name 'ValidateCredentialDestinationDirectory' `
    -Arguments @([string]$missing) `
    -SensitiveText $root `
    -Message 'missing parent is rejected with a non-sensitive error'

$junction = Join-Path $root 'junction-parent'
try {
    New-Item -ItemType Junction -Path $junction -Target $realParent -ErrorAction Stop | Out-Null
    Assert-PrivateMethodThrowsSafe `
        -Type $hostType `
        -Name 'ValidateCredentialDestinationDirectory' `
        -Arguments @([string](Join-Path $junction 'credentials.json')) `
        -SensitiveText $root `
        -Message 'runtime rejects a reparse-point destination ancestor'
} catch {
    if ($_.Exception.Message.StartsWith('ASSERTION FAILED:', [StringComparison]::Ordinal)) { throw }
    $script:Skipped++
    Write-Warning 'Junction creation is unavailable; runtime reparse assertion skipped on this host.'
}

$uncParentUnderTest = [Environment]::GetEnvironmentVariable('TAIPOWER_AMI_TEST_UNC_PARENT')
if ([string]::IsNullOrWhiteSpace($uncParentUnderTest)) {
    $script:Skipped++
    Write-Warning 'Live UNC identity test skipped; set TAIPOWER_AMI_TEST_UNC_PARENT to an existing reviewed share directory.'
} else {
    if (-not $uncParentUnderTest.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw 'TAIPOWER_AMI_TEST_UNC_PARENT must be an absolute UNC directory.'
    }
    $uncDestination = Join-Path $uncParentUnderTest 'credentials.json'
    $expectedUncParent = [IO.Path]::GetFullPath($uncParentUnderTest).TrimEnd('\', '/')
    Assert-Equal `
        (Invoke-PrivateStaticMethod `
            -Type $hostType `
            -Name 'ValidateCredentialDestinationDirectory' `
            -Arguments @([string]$uncDestination)) `
        $expectedUncParent `
        'existing UNC parent passes handle-identity validation'
}

Write-Output ("PASS_COUNT={0};SKIP_COUNT={1}" -f $script:Passed, $script:Skipped)
