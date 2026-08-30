'use strict';

const { execFileSync } = require('child_process');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const modulePath = path.join(repoRoot, 'PublicCommon.psm1').replace(/'/g, "''");

function runPowerShell(body) {
  return execFileSync(
    'pwsh.exe',
    ['-NoProfile', '-NonInteractive', '-Command', body],
    { cwd: repoRoot, encoding: 'utf8' },
  ).trim();
}

function checkStage(stopAt, expected) {
  const command = `
    $ErrorActionPreference = 'Stop'
    Import-Module '${modulePath}' -Force
    $events = [Collections.Generic.List[string]]::new()
    $result = Invoke-TaipowerAMIOrderedRollback \
      -RestoreFiles { $events.Add('files'); if ('${stopAt}' -eq 'files') { throw 'stage stopped' } } \
      -RestoreConfiguration { $events.Add('configuration'); if ('${stopAt}' -eq 'configuration') { throw 'stage stopped' } } \
      -RestoreRegistration { $events.Add('registration'); if ('${stopAt}' -eq 'registration') { throw 'stage stopped' } }
    [Console]::Write(($events -join ',') + '|' + ($result.Errors -join ','))
  `.replace(/\\\n/g, '`\n');
  const actual = runPowerShell(command);
  if (actual !== expected) {
    throw new Error(`rollback stage order mismatch for ${stopAt}: ${actual}`);
  }
}

checkStage('files', 'files|filesystem');
checkStage('configuration', 'files,configuration|CredentialDestination');
checkStage('registration', 'files,configuration,registration|Native Messaging registration');
checkStage('none', 'files,configuration,registration|');

const mutexCommand = `
  $ErrorActionPreference = 'Stop'
  Import-Module '${modulePath}' -Force
  try { Invoke-TaipowerAMIWithUserInstallMutex -Action { throw 'stage stopped' } } catch {}
  $child = @'
Import-Module '${modulePath}' -Force
$m = Enter-TaipowerAMIUserInstallMutex -TimeoutMilliseconds 2000
try { [Console]::Write('acquired') } finally { Exit-TaipowerAMIUserInstallMutex -Mutex $m }
'@
  & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command $child
  if ($LASTEXITCODE -ne 0) { throw 'mutex acquisition check failed' }
`;

if (runPowerShell(mutexCommand) !== 'acquired') {
  throw new Error('mutex was not released after the stopped setup stage');
}

console.log('Transaction order and mutex tests passed: 5');
