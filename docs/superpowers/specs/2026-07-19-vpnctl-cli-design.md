# vpnctl CLI Design

## Goal

Turn the existing ExpressVPN and Hotspot Shield automation scripts into one
dependency-free PowerShell CLI intended primarily for use by other tools. The
CLI must expose a stable argument, JSON, and exit-code contract while retaining
the existing scripts for backward compatibility.

## Command interface

The entry point is `vpnctl.ps1` and uses conventional positional commands and
long options:

```powershell
.\vpnctl.ps1 status --provider expressvpn
.\vpnctl.ps1 connect --provider hotspot-shield --location Germany
.\vpnctl.ps1 connect --provider expressvpn
.\vpnctl.ps1 disconnect --provider expressvpn
.\vpnctl.ps1 locations --provider hotspot-shield
```

Supported commands:

- `status`: return the provider's connection state and selected location.
- `connect`: connect to `--location`, or to the current selection when the
  option is omitted.
- `disconnect`: disconnect the provider.
- `locations`: return the locations currently exposed by the provider UI.

Supported global options:

- `--provider <expressvpn|hotspot-shield>` is required.
- `--location <name>` is valid only for `connect`.
- `--timeout <seconds>` overrides the provider's default operation timeout.
- `--text` selects human-readable output instead of JSON.
- `--help` prints usage information. Help is text because it is documentation,
  not an operation result.

Commands and provider values are case-insensitive. Unknown commands, options,
missing option values, invalid timeouts, and invalid option/command
combinations are usage errors.

## Architecture

`vpnctl.ps1` owns argument parsing, validation, provider dispatch, result
serialization, and process exit codes. It imports internal provider modules:

- `src/ExpressVpnProvider.psm1`
- `src/HotspotShieldProvider.psm1`

Each provider module owns only its vendor-specific UI Automation behavior. It
exposes the same internal operations: status, connect, disconnect, and
locations. Provider operations return objects or throw typed errors; they do
not format console output or terminate the process.

Shared result and error helpers live in `src/VpnCtl.Common.psm1`. The CLI is the
only layer allowed to serialize output and call `exit`.

The existing `Switch-ExpressVpn.ps1` and `Switch-HotspotShield.ps1` entry points
remain supported. They become compatibility wrappers over the provider layer
and preserve their current PowerShell parameters, human-readable output, and
documented exit codes.

## JSON contract

JSON is the default and stdout contains exactly one JSON document per
invocation. Informational and diagnostic output must not be written to stdout.

Successful responses use this envelope:

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

Failed responses use the same envelope:

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

Envelope fields are always present. `provider` and `command` are null when
argument parsing fails before they can be identified.

Command data shapes:

- `status`: `state`, `location`, and optional `tunnel`.
- `connect`: final `state`, selected `location`, and `changed` boolean.
- `disconnect`: final `state` and `changed` boolean.
- `locations`: a `locations` array. Each entry has at least `name`; provider
  codes and region/group names are included when available.

State values are normalized lowercase identifiers such as `connected`,
`disconnected`, `connecting`, and `unknown`. Provider display strings are not
used as state identifiers.

Text mode writes a concise human-readable rendering of the same result object.
It does not alter behavior or exit-code selection.

## Exit codes and errors

- `0`: success, including already-connected and already-disconnected no-ops.
- `1`: operational error such as app not installed, unexpected UI, ambiguous
  location, or no matching location.
- `2`: timeout waiting for the requested state.
- `3`: the provider explicitly reported a connection failure.
- `64`: invalid command-line usage.

Every nonzero exit in normal CLI operation produces an `ok: false` result.
PowerShell parse failures outside the script's control are avoided by using a
custom parser rather than a parameter block that rejects arguments before the
JSON error handler can run.

Errors are categorized internally and mapped to a stable machine error code,
message, and process exit code at the CLI boundary. Error messages may improve
over time; machine callers must branch on the JSON error code or process exit
code rather than matching message text.

## Compatibility and constraints

The project remains compatible with Windows PowerShell 5.1 and requires no
third-party modules or build step. It still requires an interactive, unlocked
Windows desktop because provider control uses Microsoft UI Automation.

Location enumeration remains subject to vendor UI virtualization. The JSON
result reports only locations realized by the current provider UI, matching the
existing behavior; direct connection by location name may still reach entries
not returned by `locations`.

## Testing

Automated tests exercise the CLI without requiring either VPN application by
injecting or substituting provider operations. Tests cover:

- command and option parsing, including case insensitivity;
- invalid arguments and exit code 64;
- provider dispatch and operation arguments;
- one-document stdout behavior;
- success and error JSON envelope stability;
- each command's data shape;
- operational, timeout, and provider-failure exit-code mapping;
- text-mode rendering;
- compatibility-wrapper argument mapping.

Provider UI selectors and real connection behavior require manual integration
testing on Windows machines with the corresponding signed-in application.

## Out of scope

- Building or distributing a standalone executable.
- Installing a command globally or modifying `PATH`.
- Running without an interactive desktop.
- Adding VPN providers beyond ExpressVPN and Hotspot Shield.
- Promising a complete location inventory when a vendor virtualizes its UI.
