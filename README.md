# Windows VPN Tools

`vpnctl.ps1` provides JSON-first command-line control for ExpressVPN and
Hotspot Shield on Windows. It drives the vendors' desktop applications through
Microsoft UI Automation and is intended primarily for scripts and other tools.
It requires no third-party PowerShell modules or build step.

The older `Switch-ExpressVpn.ps1` and `Switch-HotspotShield.ps1` interfaces
remain available for existing human-oriented workflows.

## Requirements

- Windows 10 or 11 with the selected VPN application installed and signed in.
- Windows PowerShell 5.1.
- An interactive, unlocked desktop session. UI Automation cannot operate on a
  locked screen, in a headless session, or in a Task Scheduler job that runs
  without a logged-in user.

The application window does not need to be focused or in front. If execution
policy blocks local scripts, add `-ExecutionPolicy Bypass` to the
`powershell` examples below.

## vpnctl command interface

The command syntax is:

```text
vpnctl.ps1 <status|connect|disconnect|locations> --provider <expressvpn|hotspot-shield> [options]
```

The exact provider identifiers are `expressvpn` and `hotspot-shield`.
Commands and provider values are case-insensitive.

Commands:

- `status` returns the connection state and selected location.
- `connect` connects to `--location`, or to the application's current
  selection when no location is supplied.
- `disconnect` disconnects the selected provider.
- `locations` returns the locations currently exposed by the provider UI.

Options:

- `--provider <expressvpn|hotspot-shield>` is required for every operation.
- `--location <name>` is valid only with `connect`.
- `--timeout <seconds>` supplies a positive integer operation timeout.
- `--text` selects concise human-readable output instead of JSON.
- `--help` by itself prints usage text and exits successfully.

Unknown or duplicate options, unknown commands or providers, missing option
values, non-positive or non-integer timeouts, and invalid option combinations
are usage errors.

### Examples

```powershell
# Inspect current state
.\vpnctl.ps1 status --provider expressvpn

# Connect to the current selection
.\vpnctl.ps1 connect --provider expressvpn

# Connect to a location containing spaces, with a timeout override
.\vpnctl.ps1 connect --provider hotspot-shield `
    --location "New York" --timeout 45

# Disconnect
.\vpnctl.ps1 disconnect --provider expressvpn

# Enumerate locations currently exposed by the UI
.\vpnctl.ps1 locations --provider hotspot-shield

# Render the same operation as human-readable text
.\vpnctl.ps1 status --provider expressvpn --text
```

A PowerShell caller can parse the default result directly:

```powershell
$result = powershell -NoProfile -File .\vpnctl.ps1 status `
    --provider expressvpn | ConvertFrom-Json
if (-not $result.ok) { throw $result.error.message }
```

When the process exit code is also needed, invoke first and then read
`$LASTEXITCODE`:

```powershell
$json = powershell -NoProfile -File .\vpnctl.ps1 disconnect `
    --provider hotspot-shield
$exitCode = $LASTEXITCODE
$result = $json | ConvertFrom-Json
```

## JSON contract

JSON is the default for operational commands. Standard output contains exactly
one compressed JSON document per invocation; informational and diagnostic
output is not mixed into it. Help and `--text` are the intentional text output
paths.

Every JSON response has all five envelope fields in this order:

```json
{
  "ok": true,
  "provider": "expressvpn",
  "command": "status",
  "data": {
    "state": "connected",
    "location": "Germany",
    "tunnel": "up"
  },
  "error": null
}
```

A failed operation uses the same envelope:

```json
{
  "ok": false,
  "provider": "expressvpn",
  "command": "connect",
  "data": null,
  "error": {
    "code": "timeout",
    "message": "ExpressVPN did not reach the connected state within 60 seconds."
  }
}
```

`provider` and `command` can be `null` when parsing fails before they are
identified. Callers should branch on `ok`, `error.code`, or the process exit
code rather than matching error message text.

Command-specific `data` shapes:

- `status`: `state`, `location`, and optional `tunnel`.
- `connect`: final `state`, selected `location`, and Boolean `changed`.
- `disconnect`: final `state` and Boolean `changed`.
- `locations`: a `locations` array whose entries contain at least `name`.
  Entries can also contain provider codes or region/group names.

State identifiers are normalized lowercase values such as `connected`,
`disconnected`, `connecting`, and `unknown`.

### Exit codes

| Code | Meaning | Typical error code |
| ---: | --- | --- |
| 0 | Success, including an already-satisfied connection state | none |
| 1 | Operational error: missing app, unexpected UI, ambiguous location, or no match | `operational_error` |
| 2 | Timed out waiting for the requested state | `timeout` |
| 3 | The provider explicitly reported a connection failure | `provider_failure` |
| 64 | Invalid command-line usage | `usage_error` |

Every nonzero exit during normal CLI operation produces an `ok: false` JSON
result. Text mode changes rendering only; it does not change provider behavior
or exit-code selection. Errors remain JSON so machine-readable failures are
preserved.

## Legacy compatibility

The original scripts retain their PowerShell parameter interfaces and
human-readable output.

### ExpressVPN

```powershell
.\Switch-ExpressVpn.ps1 -Status
.\Switch-ExpressVpn.ps1 -ListLocations
.\Switch-ExpressVpn.ps1 -Location "Germany"
.\Switch-ExpressVpn.ps1 -Location "USA - San Francisco"
.\Switch-ExpressVpn.ps1 -Connect
.\Switch-ExpressVpn.ps1 -Disconnect
```

### Hotspot Shield

```powershell
.\Switch-HotspotShield.ps1 -Status
.\Switch-HotspotShield.ps1 -ListLocations
.\Switch-HotspotShield.ps1 -Location "United Kingdom"
.\Switch-HotspotShield.ps1 -Location "Miami"
.\Switch-HotspotShield.ps1 -Location "USNYC"
.\Switch-HotspotShield.ps1 -Connect
.\Switch-HotspotShield.ps1 -Disconnect
```

Both legacy scripts accept `-TimeoutSec`. Their established exit codes remain
`0` for success, `1` for operational errors, `2` for timeouts, and `3` when
Hotspot Shield explicitly reports that it cannot connect.

## Why UI Automation?

ExpressVPN's Windows CLI executable is an internal client that does not provide
a usable scripting interface, and Hotspot Shield has no Windows CLI or local
API. Both desktop applications expose controls through Microsoft UI
Automation, allowing these tools to operate the real vendor UI without taking
over the mouse.

## Limitations

- Vendor UI redesigns can require selector updates.
- Location pickers are virtualized. `locations` and `-ListLocations` report
  only entries realized by the current UI; direct connection by name can still
  reach entries omitted from that list.
- These are unofficial tools and are not affiliated with, endorsed by, or
  supported by ExpressVPN or Hotspot Shield/Pango.

## License

MIT — see [LICENSE](LICENSE).
