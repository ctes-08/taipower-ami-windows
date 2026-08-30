# Compatibility contract

The public Windows Companion and the private production channel share this
version 2.0.1 identity and wire contract. A change to any item below requires
an explicit protocol version change and a coordinated Home Assistant
migration.

## Fixed identities

- Chrome extension ID: `ajnbiemabobkigpbnfmoekolceigkica`
- Native Messaging host: `tw.taipower_ami.native_host_v2`
- Allowed origin:
  `chrome-extension://ajnbiemabobkigpbnfmoekolceigkica/`

The extension manifest's public key is intentionally retained so an unpacked
or self-distributed build keeps the same ID. It is not a signing private key.

## Native request

The Native Messaging request is one length-prefixed UTF-8 JSON object with
exactly these five fields:

```json
{
  "version": 1,
  "action": "import",
  "session": "<opaque value>",
  "enkey": "<opaque AMI identifier>",
  "captured_day": "YYYY-MM-DD"
}
```

Unknown or missing fields, malformed UTF-8, oversized messages, an unexpected
origin, stale dates, and invalid opaque values are rejected. Credential values
must never be written to stdout except inside the required browser-to-host
request framing, and must never be written to stderr, logs, metadata, test
evidence, or error responses.

## Native response

The host returns exactly one bounded length-prefixed UTF-8 JSON response. A
successful response retains the current semantic fields:

```json
{
  "status": "ok",
  "imported_at": "<ISO-8601 local timestamp>",
  "validation": "official_read_only_yearlist",
  "validation_rows": 12,
  "secrets_printed": false
}
```

Errors contain a safe human-readable message and `secrets_printed: false`.
They never echo input values or raw Taipower response bodies.

## Home Assistant handoff document

The destination is operator configuration, never a compiled-in household
path. The atomically replaced UTF-8 JSON document remains schema version 1:

```json
{
  "version": 1,
  "session": "<opaque value>",
  "enkey": "<opaque AMI identifier>",
  "imported_at": "<ISO-8601 local timestamp>",
  "captured_day": "YYYY-MM-DD",
  "session_refreshed_at": null
}
```

The companion writes only this document. It does not receive a Home Assistant
administrator token and does not modify Home Assistant configuration.

The operator configuration contract is fixed to the 64-bit registry view:

- key: `HKCU\Software\TaipowerAMI`
- value: `CredentialDestination`
- type: `REG_SZ` (never `REG_EXPAND_SZ`)

The value is an absolute local or native UNC path ending in the exact filename
`credentials.json`. Mapped network drives are rejected. The host and installer
reject relative, drive-relative, device, extended-length,
environment-expanded, malformed, unavailable-parent, and existing
reparse-ancestry destinations. During every handoff, the host rereads the
Registry64 value and checks the opened parent directory's final handle path
before the temporary write, before atomic replacement, and before the final
readback. Errors never echo the configured path.

## Official validation request

Before handoff, the host performs the existing single read-only `yearlist`
request against the fixed official HTTPS origin. It does not enumerate API
routes, automate login, bypass human verification, or submit account
credentials.
