# Security policy

Never attach an unredacted Taipower HAR, SESSION, enkey, electric number,
account identifier, Home Assistant token, pairing credential, SMB credential,
browser profile, signing key, or private certificate to a public issue.

Report a suspected vulnerability privately through the repository's
[Security Advisories](https://github.com/ctes-08/taipower-ami-windows/security/advisories/new)
page. Do not disclose credentials or identifying captures in a public issue.

The supported workflow is user-authorized and read-only. It does not bypass
human verification, automate login, expose a general Home Assistant token,
or run the Native Messaging host with administrator privileges.

Current public artifacts are unsigned and must be identified as such. A future
public SignPath Foundation signature is permitted only after approval and only
under [CODE_SIGNING_POLICY.md](CODE_SIGNING_POLICY.md). The private YubiKey/WDAC
signer belongs to a separate private release channel and is never invoked by
this repository.

The public LocalAppData installation and its HKCU configuration are writable
by the current user. Runtime registry rereads, reparse rejection, and final
directory-handle comparison reduce path confusion and time-of-check/time-of-use
risk during a handoff, but they do not create a security boundary against code
that already runs as that user. Likewise, SHA-256 detects changed bytes but an
unsigned hash obtained from the same compromised download channel does not
authenticate a publisher.

Install and uninstall operations use one per-user named mutex plus guarded
Registry64 updates: each product-owned value is compared with its expected
snapshot, changed, and read back while the mutex is held. This serializes all
project tools and rejects conflicts they can observe. The ordinary Windows
registry API does not make that sequence a lock-free compare-and-swap against
arbitrary same-user software that ignores the mutex, so the project does not
claim that stronger guarantee. A future requirement for adversarial concurrent
writers would need a separately reviewed, precompiled and signed transactional
registry helper rather than runtime-generated native interop code.
