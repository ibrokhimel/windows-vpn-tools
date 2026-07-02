# Windows VPN Tools

Command-line control for two Windows VPN apps that don't ship a working CLI:
**ExpressVPN** and **Hotspot Shield**. Each tool is a single self-contained
PowerShell script that drives the vendor's own desktop app through Microsoft
UI Automation, so you get scriptable `connect` / `disconnect` / `switch
location` without any third-party dependencies.

## Why UI Automation?

Neither app exposes a usable control surface on Windows:

- **ExpressVPN** ships `ExpressVPN.CLI.exe`, but it's an internal gRPC client
  that produces no console output and can't be scripted.
- **Hotspot Shield** has no CLI at all on Windows (only its Linux build does),
  no local API port, and stores its settings in an encrypted blob.

Both apps *do* expose their UI through Microsoft UI Automation with stable
element IDs, so these scripts click the real buttons for you — reliably, in the
background, without taking over your mouse.

## Tools

### `Switch-ExpressVpn.ps1`

```powershell
.\Switch-ExpressVpn.ps1 -Status                        # state, location, tunnel up/down
.\Switch-ExpressVpn.ps1 -ListLocations                 # all countries, grouped by region
.\Switch-ExpressVpn.ps1 -Location "Germany"            # connect to a country
.\Switch-ExpressVpn.ps1 -Location "USA - San Francisco" # ...or a specific city
.\Switch-ExpressVpn.ps1 -Location "Smart Location"     # ...or the recommended server
.\Switch-ExpressVpn.ps1 -Connect                       # connect to current selection
.\Switch-ExpressVpn.ps1 -Disconnect
```

`-Status` reads ExpressVPN's own authoritative state text ("Connected",
"Connecting", "Not Connected") plus the live tunnel adapter status.

### `Switch-HotspotShield.ps1`

```powershell
.\Switch-HotspotShield.ps1 -Status                     # state + selected location
.\Switch-HotspotShield.ps1 -ListLocations              # all 100+ locations
.\Switch-HotspotShield.ps1 -Location "United Kingdom"  # connect to a country
.\Switch-HotspotShield.ps1 -Location "Miami"           # ...or a city
.\Switch-HotspotShield.ps1 -Location "USNYC"           # ...or a location code
.\Switch-HotspotShield.ps1 -Connect                    # connect to current selection
.\Switch-HotspotShield.ps1 -Disconnect
```

## Requirements

- Windows 10/11 with the respective VPN app installed and signed in.
- An **interactive, unlocked desktop session.** These tools drive a GUI app, so
  they won't work on a locked screen, over a headless session, or from a
  Task Scheduler job that runs without a logged-in user.
- Windows PowerShell 5.1 (built in) — no modules to install.

If your execution policy blocks scripts, run them like:

```powershell
powershell -ExecutionPolicy Bypass -File .\Switch-ExpressVpn.ps1 -Status
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (app not installed, no matching location, unexpected UI, ...) |
| 2 | Timed out waiting for the connection state to change |
| 3 | The app itself reported it couldn't connect (Hotspot Shield only) |

## Notes & limitations

- **App updates may move things.** These scripts target the apps' current UI
  automation IDs. A major redesign could require small tweaks.
- Location lists are virtualized by the apps, so `-ListLocations` shows what the
  picker has realized; every location is still reachable by name via `-Location`.
- These are unofficial tools and are **not affiliated with, endorsed by, or
  supported by** ExpressVPN or Hotspot Shield / Pango. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).
