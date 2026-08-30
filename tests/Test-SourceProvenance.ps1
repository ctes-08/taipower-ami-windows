[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
Import-Module (Join-Path $repoRoot 'PublicBuild.psm1') -Force
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
    $script:Passed++
}

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('Test Git command failed: git ' + ($Arguments -join ' ') + "`n" + ($output -join "`n"))
    }
    return $output
}

$testRoot = Join-Path $repoRoot ('.test-output\source-provenance-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    Invoke-TestGit -Repository $testRoot -Arguments @('init', '--quiet') | Out-Null
    Invoke-TestGit -Repository $testRoot -Arguments @('config', 'user.name', 'Taipower AMI provenance test') | Out-Null
    Invoke-TestGit -Repository $testRoot -Arguments @('config', 'user.email', 'provenance-test.invalid') | Out-Null
    Invoke-TestGit -Repository $testRoot -Arguments @('config', 'commit.gpgsign', 'false') | Out-Null

    $trackedPath = Join-Path $testRoot 'tracked.txt'
    [IO.File]::WriteAllText($trackedPath, "baseline`n", [Text.UTF8Encoding]::new($false))
    Invoke-TestGit -Repository $testRoot -Arguments @('add', '--', 'tracked.txt') | Out-Null
    Invoke-TestGit -Repository $testRoot -Arguments @('commit', '--quiet', '--no-gpg-sign', '-m', 'baseline') | Out-Null

    $clean = Get-TaipowerAMISourceProvenance -SourceRoot $testRoot
    Assert-True ($clean.TreeState -ceq 'clean') 'committed repository is reported clean'
    Assert-True ($clean.Commit -cmatch '^[0-9a-f]{40}$') 'clean provenance records the exact HEAD commit'

    [IO.File]::WriteAllText($trackedPath, "staged change`n", [Text.UTF8Encoding]::new($false))
    Invoke-TestGit -Repository $testRoot -Arguments @('add', '--', 'tracked.txt') | Out-Null

    & git -C $testRoot diff --quiet --
    Assert-True ($LASTEXITCODE -eq 0) 'staged-only fixture has no unstaged changes'
    & git -C $testRoot diff --cached --quiet --
    Assert-True ($LASTEXITCODE -eq 1) 'staged-only fixture has a cached change'

    $staged = Get-TaipowerAMISourceProvenance -SourceRoot $testRoot
    Assert-True ($staged.TreeState -cne 'clean') 'staged-only change is never reported clean'
    Assert-True ($staged.Commit -ceq $clean.Commit) 'dirty provenance still records the current HEAD commit'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host ("Source provenance tests passed: {0}" -f $script:Passed)
