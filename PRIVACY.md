# Privacy policy

## Scope

This policy covers the Taipower AMI Windows Companion: its fixed-ID Chrome
extension, Native Messaging host, and user-scoped installer. The separate Home
Assistant integration has its own repository and documentation.

The companion has no project-operated server, telemetry, analytics, advertising,
crash-report upload, or remote account service.

## Data processed during a handoff

A handoff starts only when the user presses the extension button while viewing
the official Taipower website after completing the normal visible login and any
human-verification step.

The extension reads only:

- the single secure, HTTP-only `SESSION` cookie scoped to the official Taipower
  electronic-billing path;
- the AMI identifier present in the official dashboard URL; and
- the current calendar day in the Asia/Taipei time zone.

It does not read, store, or fill the Taipower account name or password. It does
not read cookies from other websites, automate CAPTCHA or Cloudflare Turnstile,
use browser remote debugging, or perform unattended login.

## Network and local destinations

The Native Messaging host sends one HTTPS GET request to the fixed official
`https://service.taipower.com.tw/ebpps2/amichart/api/yearlist` endpoint to
confirm that the user-provided session and AMI identifier are currently
authorized. The session is sent to Taipower as its normal cookie and the AMI
identifier is sent as the endpoint parameter. The companion rejects redirects,
unexpected content, and authentication failures; it does not retain the
response body.

After successful validation, the Native Messaging host writes the minimal
credential handoff document to the absolute local or native UNC
`credentials.json` destination selected by the operator during installation.
No handoff data is sent to the project maintainer or to a project-controlled
service. A UNC destination sends the write through the operating system's SMB
client to the server chosen and administered by the operator. Transport
confidentiality depends on that SMB client, server, share, and network
configuration; this project does not claim or configure SMB encryption.

## Storage and retention

Chrome retains the official website's cookie according to Taipower's and
Chrome's own session rules. The extension and Native Messaging process do not
create another persistent copy; they hold the handoff values only for the
duration of the user-initiated operation. The destination `credentials.json`
persists until it is overwritten or deleted by the operator or the receiving
Home Assistant system. The Windows uninstaller deliberately does not delete the
credential file or its parent directory, because that location may be remote or
shared with a separately managed Home Assistant installation.

The companion does not place credentials in release metadata, application logs,
GitHub Actions artifacts, diagnostics, crash reports, or the Windows registry.
`HKCU\Software\TaipowerAMI` stores only the operator-selected destination path,
and Chrome's `HKCU\Software\Google\Chrome\NativeMessagingHosts` registration
stores only the Native Messaging manifest path. Neither location stores
`SESSION` or the AMI identifier.

The extension requests `activeTab`, `cookies`, `nativeMessaging`, and
`scripting` permissions, with host access restricted to the official
`https://service.taipower.com.tw/*` origin. The code uses those permissions only
for the explicit handoff described above.

## Operator control

The operator may stop future handoffs by disabling or removing the Chrome
extension, uninstalling the Windows Companion, or removing its Native Messaging
registration. The operator remains responsible for protecting and, when
appropriate, deleting the destination `credentials.json` file.

Security reports must follow [SECURITY.md](SECURITY.md) and must never contain a
live session, AMI identifier, HAR, credential file, browser profile, private
path, or account information.
