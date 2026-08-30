# Code signing policy

## Status

The first public release is expected to be unsigned. This project intends to
apply to the SignPath Foundation open-source program only after the repository
is public, the unsigned release process has been exercised, and the application
requirements can be evaluated against an established public release.

If the application is approved, covered Windows release artifacts will use the
required attribution:

> Free code signing provided by SignPath.io, certificate by SignPath Foundation

See [SignPath.io](https://signpath.io/) and the
[SignPath Foundation](https://signpath.org/).

Until that approval and integration are complete, no artifact may claim to be
signed by SignPath Foundation.

## Project and roles

- Project: Taipower AMI Windows Companion
- Repository: <https://github.com/ctes-08/taipower-ami-windows>
- License: Apache License 2.0
- Authors and committers: `ctes-08`.
- Reviewers: `ctes-08`; changes from external contributors require maintainer
  review before merge.
- Approvers: `ctes-08`; every signing request requires manual approval.

Every person assigned to one of these roles must use multi-factor
authentication for GitHub and SignPath.

## Eligible project-owned code

The following project-owned files built or packaged from this repository are
eligible for a future public SignPath signature:

- `NativeHost/TaipowerAMINativeHostV2.exe`;
- `Installer/Install-UserScoped.ps1`;
- `Installer/Uninstall-UserScoped.ps1`; and
- `Installer/PublicCommon.psm1`.

The Chrome extension bundle, documentation, checksums, third-party tools,
private release artifacts, and code not produced from this repository are not
eligible under this policy. The artifact configuration must identify each
eligible path explicitly and must never sign an unrelated or substituted file.

The Native Host executable must retain the fixed compatibility contract documented
in [docs/COMPATIBILITY_CONTRACT.md](docs/COMPATIBILITY_CONTRACT.md), including
the extension ID and Native Messaging host name. Product name, file version, and
product version must match the reviewed release and the future SignPath artifact
configuration.

## Trusted build and approval

A future signed release must:

1. originate from this repository's reviewed default-branch source;
2. be built by the `Public Windows gate` GitHub Actions workflow entirely on a
   GitHub-hosted Windows runner using the locked deterministic toolchain;
3. pass the complete public test, provenance, package-neutrality, and two-path
   deterministic-build gates;
4. be uploaded by that workflow before a signing request is submitted;
5. pass SignPath trusted-build and origin verification;
6. receive manual approval from the signing approver;
7. return a valid timestamped Authenticode signature identifying SignPath
   Foundation; and
8. be repackaged with signed release metadata and newly computed SHA-256 values
   before publication.

The current `public_unsigned` package validator deliberately rejects signed
input. A future `public_signed` post-sign validator and packager must verify all
expected Authenticode signatures and timestamps before regenerating metadata,
checksums, the final ZIP, and its sidecar. Approval of this policy alone does not
authorize adding SignPath credentials or weakening the unsigned validator.

Local builds, manually substituted executables, artifacts from forks or
self-hosted runners, and files produced by the private signing workflow are not
eligible for public SignPath signing.

## Privacy and system changes

The companion transfers information only when the user explicitly requests a
handoff. The complete data flow, retention behavior, and absence of
project-operated telemetry are documented in [PRIVACY.md](PRIVACY.md).

Installation registers one user-scoped Chrome Native Messaging host, installs
the companion under the current user's LocalAppData directory, and stores one
operator-selected destination path in HKCU. These changes are described before
installation in [docs/INSTALLATION.md](docs/INSTALLATION.md), which also provides
the complete uninstallation procedure.

## Incident response

If a signed artifact cannot be traced to the approved source and workflow, has
unexpected metadata, exposes credentials, or is suspected of certificate
misuse, publication and signing must stop. Preserve only credential-free build
evidence, report the issue through the private process in
[SECURITY.md](SECURITY.md), and notify SignPath when certificate suspension or
revocation may be required.
