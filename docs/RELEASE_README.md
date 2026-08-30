# Taipower AMI Windows Companion — unsigned package

This archive contains the user-scoped Windows companion for a user-initiated
Taipower AMI credential handoff to Home Assistant. It is unsigned, never
elevates, and installs for the current Chrome user under LocalAppData.

Before extraction, verify the ZIP and its sidecar by following the trusted
release-page copy of the installation procedure. After extraction, read the
included `INSTALLATION.md` before running a script. It contains the exact
SHA-256, Mark-of-the-Web, installation, Chrome unpacked-extension, and
uninstall procedure. `SECURITY.md` defines the trust boundary and the
information that must never be attached to a public issue.

Package contents:

- `ChromeExtension/` — the fixed-ID unpacked Chrome extension;
- `NativeHost/` — the unsigned Native Messaging executable and manifest
  template;
- `Installer/` — the ordinary-user installer, uninstaller, and shared module;
- `release_metadata.json` — version, compatibility identity, provenance, and
  unsigned build status;
- `SHA256SUMS` — exact coverage of every other file in the extracted package;
- `INSTALLATION.md` and `SECURITY.md` — offline operator guidance.

The user must sign in to the official Taipower website in a normal visible
Chrome window and personally complete any human-verification step. This
package does not store or fill the account password, automate human
verification, or perform unattended login.

The Home Assistant custom integration is distributed separately. This Windows
package writes only the existing reviewed credentials schema to the destination
configured by the operator; it does not install or configure Home Assistant.
