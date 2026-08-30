# Public Windows VM validation gate

Run this matrix on a disposable Windows VM before publishing a release. Use only the unsigned public package and a test `credentials.json` destination. Do not use private signing, WDAC policy, or household deployment settings.

## Preconditions

- A clean supported Windows VM with 64-bit Chrome.
- A real local destination and, separately, a real writable UNC share ending in `credentials.json`.
- The release ZIP and published SHA-256 verified before extraction.

## Required matrix

1. **Clean install** — install with an explicit local destination; verify the extension ID, host name, HKCU Registry64 manifest registration, absolute manifest EXE path, and `CredentialDestination`.
2. **Real Chrome call** — load the unpacked extension, sign in normally, invoke the handoff, and confirm Chrome receives the existing protocol result and only the intended credential file changes.
3. **Real UNC** — repeat handoff to a native UNC destination. Confirm mapped drives, reparse ancestry, device paths, relative paths, and a filename other than `credentials.json` fail closed.
4. **Concurrent/interrupted install recovery** — start the project installer and uninstaller concurrently and confirm the shared current-user mutex serializes them. Confirm path, ownership, and Registry64 snapshots are taken only after the mutex is held. Interrupt staging, activation, and registry phases in separate snapshots; rerun and verify either the prior complete version or the new complete version remains. Inject a foreign/newer registry value before a guarded update and confirm it is preserved. This validates cooperating project tools and detected conflicts; it does not claim a lock-free compare-and-swap against arbitrary same-user software that ignores the mutex.
5. **Uninstall/reinstall** — uninstall while retaining the extension, reinstall, then uninstall with extension removal. Inject a failure while restoring quarantined files and confirm neither configuration nor registration is restored. Separately inject a configuration-restore failure and confirm registration stays absent. Verify credentials are never deleted and post-commit cleanup failure leaves only inert backup/quarantine evidence, never a registry pointer to a deleted host.

Record VM snapshot, Chrome version, commands, observed registry values (paths only), file hashes, and pass/fail. Never attach session, enkey, HAR, cookies, or credential contents.
