# Trust and release model

## Public channel

The public repository owns reusable source and deterministic unsigned release
candidates. A release may publish the unsigned executable, extension bundle,
build provenance, `SHA256SUMS`, archive, and archive sidecar hash. The release
must state clearly that it is unsigned.

Public CI has no access to the private YubiKey, signer certificate, signer
thumbprint, WDAC policy, production computer, household paths, or Home
Assistant credentials.

The first public release is unsigned. If the project is later accepted by the
SignPath Foundation open-source program, only the project-owned Native Host and
installer files enumerated in the
[Code signing policy](../CODE_SIGNING_POLICY.md) may be signed. The unsigned
GitHub Actions artifact remains the source-linked input; signing and
timestamping change its bytes, after which a separate public post-sign step must
regenerate metadata, checksums, ZIP, and sidecar. The resulting Publisher is
SignPath Foundation, not the private release identity.

## Private production channel

The private security workflow consumes one exact reviewed unsigned candidate,
verifies its source commit, locked toolchain, and SHA-256, and signs that file
outside the public repository. A private post-sign packager then verifies the
signature and timestamp and builds new signed metadata, checksums, ZIP, and
sidecar hash.

Signing changes the executable hash. Unsigned and signed hashes are never
presented as interchangeable, and the private WDAC signer is not used for
public binaries.

## Deterministic build gate

An unsigned candidate is eligible for review only when:

1. the compiler and reference assemblies match the checked-in toolchain lock;
2. deterministic compilation and path mapping are enabled;
3. two clean builds from different absolute staging paths produce identical
   executable bytes and SHA-256 values;
4. the executable contains no household path or secret;
5. extension ID, host name, allowed origin, and message contract tests pass;
6. the archive and metadata are generated only after the executable passes;
   and
7. the source commit and working-tree state are recorded without embedding a
   local filesystem path.

No final release hash is approved before the common architecture is complete.

## Artifact custody

Git records source, not ignored build output. Public unsigned archives belong
in a public GitHub Release after publication. Private signed archives belong
in a private GitHub Release or equivalent access-controlled off-machine
backup. Each evidence set retains the exact source commit, toolchain lock,
unsigned hash, signed hash where applicable, metadata, archive, and sidecar.
