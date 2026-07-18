# vpnctl CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one dependency-free, JSON-first PowerShell CLI for controlling ExpressVPN and Hotspot Shield while preserving both existing script interfaces.

**Architecture:** `vpnctl.ps1` performs custom CLI parsing, dispatch, serialization, and exit-code selection. Focused common and provider modules return objects and throw categorized exceptions without writing output or exiting; compatibility scripts map their established parameters onto the same provider API.

**Tech Stack:** Windows PowerShell 5.1, Microsoft UI Automation, built-in PowerShell JSON serialization, dependency-free PowerShell test harness

## Global Constraints

- The project remains compatible with Windows PowerShell 5.1.
- Runtime operation requires no third-party modules and no build step.
- JSON is the default output and stdout contains exactly one JSON document per operational invocation.
- The supported providers are exactly `expressvpn` and `hotspot-shield`.
- The supported commands are exactly `status`, `connect`, `disconnect`, and `locations`.
- Existing `Switch-ExpressVpn.ps1` and `Switch-HotspotShield.ps1` parameters and exit codes remain supported.
- Provider control still requires an interactive, unlocked Windows desktop.
- Automated tests must not require either VPN application.
- Independent implementation workstreams use separate branches and worktrees
  based on `agent/vpnctl-integration`. Each workstream is tested, reviewed,
  pushed, opened as a pull request targeting the integration branch, and
  merged only after approval. After all workstreams are integrated, run the
  full review and verification suite, then open and merge one final pull
  request from the integration branch into `main`.

## File map

- Create `vpnctl.ps1`: executable CLI boundary, custom argument parser, dispatch, rendering, and final exit.
- Create `src/VpnCtl.Common.psm1`: categorized error type and stable result-envelope helpers.
- Create `src/ExpressVpnProvider.psm1`: ExpressVPN UI Automation and normalized provider operations.
- Create `src/HotspotShieldProvider.psm1`: Hotspot Shield UI Automation and normalized provider operations.
- Create `tests/fixtures/FakeProvider.psm1`: deterministic provider used by CLI contract tests.
- Create `tests/run-tests.ps1`: dependency-free test runner and assertions.
- Modify `Switch-ExpressVpn.ps1`: compatibility wrapper over `ExpressVpnProvider.psm1`.
- Modify `Switch-HotspotShield.ps1`: compatibility wrapper over `HotspotShieldProvider.psm1`.
- Modify `README.md`: machine-oriented CLI contract, examples, and compatibility notes.

---

### Task 1: Common result and error contract

**Files:**
- Create: `src/VpnCtl.Common.psm1`
- Create: `tests/run-tests.ps1`

**Interfaces:**
- Produces: `New-VpnCtlResult -Ok <bool> -Provider <string> -Command <string> -Data <object> -ErrorCode <string> -Message <string>`
- Produces: `New-VpnCtlException -Code <string> -Message <string> -ExitCode <int>`
- Produces: `Get-VpnCtlErrorInfo -Exception <Exception>` returning `{ code, message, exitCode }`

- [ ] **Step 1: Write failing common-contract tests**

Create the test runner with `Assert-Equal`, `Assert-True`, and a `Test-Case`
function that records failures. Import `src/VpnCtl.Common.psm1`, then add these
assertions:

```powershell
$success = New-VpnCtlResult -Ok $true -Provider 'expressvpn' -Command 'status' `
    -Data ([pscustomobject]@{ state = 'connected' })
Assert-True $success.ok 'success ok'
Assert-Equal 'expressvpn' $success.provider 'success provider'
Assert-Equal $null $success.error 'success error'

$exception = New-VpnCtlException -Code 'timeout' -Message 'too slow' -ExitCode 2
$info = Get-VpnCtlErrorInfo -Exception $exception
Assert-Equal 'timeout' $info.code 'typed error code'
Assert-Equal 2 $info.exitCode 'typed error exit'

$fallback = Get-VpnCtlErrorInfo -Exception ([Exception]::new('broken UI'))
Assert-Equal 'operational_error' $fallback.code 'fallback code'
Assert-Equal 1 $fallback.exitCode 'fallback exit'
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: nonzero exit because `VpnCtl.Common.psm1` does not exist.

- [ ] **Step 3: Implement the common contract**

Define a `VpnCtlException` class whose constructor stores `Code` and
`ExitCode`. Implement `New-VpnCtlException` to return that exception.
`Get-VpnCtlErrorInfo` recognizes `VpnCtlException`; all other exceptions map to
`operational_error` and exit 1. `New-VpnCtlResult` always returns an ordered
object with fields in this order: `ok`, `provider`, `command`, `data`, `error`.
On failure, `error` is an ordered object with `code` and `message`.

```powershell
class VpnCtlException : System.Exception {
    [string]$Code
    [int]$ExitCode
    VpnCtlException([string]$code, [string]$message, [int]$exitCode) :
        base($message) {
        $this.Code = $code
        $this.ExitCode = $exitCode
    }
}
```

Export exactly the three public functions.

- [ ] **Step 4: Run the tests to verify they pass**

Run the test command from Step 2.

Expected: exit 0 and a summary reporting all common-contract tests passed.

- [ ] **Step 5: Commit, open a PR, and merge**

```powershell
git add src/VpnCtl.Common.psm1 tests/run-tests.ps1
git commit -m "feat: add vpnctl result and error contract"
```

Push the task branch and open a pull request titled `feat: add vpnctl result
and error contract`. Merge only after its checks pass, then update the local
default branch before Task 2.

### Task 2: CLI parser, dispatch, and JSON boundary

**Files:**
- Create: `vpnctl.ps1`
- Create: `tests/fixtures/FakeProvider.psm1`
- Modify: `tests/run-tests.ps1`

**Interfaces:**
- Consumes: common module functions from Task 1.
- Produces: process interface `vpnctl.ps1 <command> --provider <provider> [--location <name>] [--timeout <seconds>] [--text]`
- Provider module contract: `Get-VpnStatus`, `Connect-Vpn`, `Disconnect-Vpn`, and `Get-VpnLocations`.
- Test seam: environment variable `VPNCTL_PROVIDER_MODULE` overrides provider module resolution only when set to an existing `.psm1` path.

- [ ] **Step 1: Add failing subprocess contract tests**

Add `Invoke-Cli` to start `powershell.exe -NoProfile -File vpnctl.ps1`, capture
stdout, stderr, and `$LASTEXITCODE`, and set `VPNCTL_PROVIDER_MODULE` to the fake
provider for each call. Add exact tests for:

```powershell
$result = Invoke-Cli @('status', '--provider', 'EXPRESSVPN')
Assert-Equal 0 $result.ExitCode 'status exit'
$json = $result.Stdout | ConvertFrom-Json
Assert-True $json.ok 'status ok'
Assert-Equal 'connected' $json.data.state 'normalized state'

$result = Invoke-Cli @('connect', '--provider', 'hotspot-shield',
    '--location', 'New York', '--timeout', '12')
$json = $result.Stdout | ConvertFrom-Json
Assert-Equal 'New York' $json.data.location 'location forwarded'

$result = Invoke-Cli @('disconnect', '--provider', 'expressvpn')
Assert-Equal 'disconnected' (($result.Stdout | ConvertFrom-Json).data.state) 'disconnect'

$result = Invoke-Cli @('locations', '--provider', 'expressvpn')
Assert-Equal 2 (($result.Stdout | ConvertFrom-Json).data.locations.Count) 'locations'

$result = Invoke-Cli @('status', '--provider', 'unknown')
Assert-Equal 64 $result.ExitCode 'invalid provider exit'
Assert-Equal 'usage_error' (($result.Stdout | ConvertFrom-Json).error.code) 'usage code'

$result = Invoke-Cli @('status', '--provider', 'expressvpn', '--location', 'Paris')
Assert-Equal 64 $result.ExitCode 'invalid option combination'

$result = Invoke-Cli @('connect', '--provider', 'expressvpn', '--timeout', '0')
Assert-Equal 64 $result.ExitCode 'invalid timeout'

$result = Invoke-Cli @('--help')
Assert-Equal 0 $result.ExitCode 'help exit'
Assert-True ($result.Stdout -match 'vpnctl\.ps1') 'help text'
```

For every JSON case, assert `@($result.Stdout -split "`r?`n" | Where-Object {
$_ }).Count -eq 1` and stderr is empty.

- [ ] **Step 2: Run the CLI tests to verify they fail**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Expected: nonzero exit because `vpnctl.ps1` and the fake provider do not exist.

- [ ] **Step 3: Implement the fake provider**

Export the four provider functions. Return:

```powershell
[pscustomobject]@{ state = 'connected'; location = 'Test Location'; tunnel = 'up' }
[pscustomobject]@{ state = 'connected'; location = $Location; changed = $true }
[pscustomobject]@{ state = 'disconnected'; changed = $true }
[pscustomobject]@{ locations = @(
    [pscustomobject]@{ name = 'Germany' },
    [pscustomobject]@{ name = 'New York'; code = 'USNYC' }
) }
```

`Connect-Vpn` accepts `[string]$Location` and `[int]$TimeoutSec`; the other
mutating command accepts `[int]$TimeoutSec`.

- [ ] **Step 4: Implement the CLI parser and dispatcher**

Use `param([Parameter(ValueFromRemainingArguments = $true)][object[]]$CliArgs)`
so script-owned validation can always return JSON. Parse options with an index
loop; reject duplicate options, unknown options, missing values, non-integer or
non-positive timeouts, invalid providers, and invalid option combinations.

Resolve normal modules from:

```powershell
$providerFiles = @{
    'expressvpn' = 'src/ExpressVpnProvider.psm1'
    'hotspot-shield' = 'src/HotspotShieldProvider.psm1'
}
```

Dispatch `connect` with or without `-Location`, applying provider defaults when
`--timeout` is absent. Serialize with:

```powershell
[Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 8 -Compress))
```

Catch all exceptions, use `Get-VpnCtlErrorInfo`, emit one failure envelope, and
exit with its mapped code. Usage errors use code `usage_error` and exit 64.
Help is the only non-JSON success path.

- [ ] **Step 5: Implement and test text rendering**

Add tests confirming `--text` returns non-JSON text containing provider,
command, state, and location for status, and that a fake typed timeout still
exits 2. Add `Format-VpnCtlText` to render scalar data properties and location
entries without changing dispatch or exit behavior.

- [ ] **Step 6: Run tests to verify they pass**

Run the test command from Step 2.

Expected: exit 0; all parser, dispatch, JSON, exit-code, help, and text tests
pass.

- [ ] **Step 7: Commit, open a PR, and merge**

```powershell
git add vpnctl.ps1 tests/fixtures/FakeProvider.psm1 tests/run-tests.ps1
git commit -m "feat: add JSON-first vpnctl command"
```

Push the task branch and open a pull request with the same title as the commit.
Merge only after its checks pass, then update the local default branch.

### Task 3: ExpressVPN provider module

**Files:**
- Create: `src/ExpressVpnProvider.psm1`
- Modify: `tests/run-tests.ps1`

**Interfaces:**
- Consumes: `New-VpnCtlException` from the common module.
- Produces: `Get-VpnStatus`, `Connect-Vpn`, `Disconnect-Vpn`, `Get-VpnLocations`.
- `Connect-Vpn([string]$Location, [int]$TimeoutSec = 60)` permits an empty location.
- `Disconnect-Vpn([int]$TimeoutSec = 30)`.

- [ ] **Step 1: Add failing static provider-contract tests**

Import the module without invoking a VPN app. Assert all four exported commands
exist and that no exported command named `Show-*`, `Get-EvpnWindow`, or
`Connect-ToLocation` exists. Parse the module AST and assert it contains no
`Write-Host`, `Write-Warning`, or `exit` command.

- [ ] **Step 2: Run tests to verify they fail**

Run the full test suite.

Expected: failure because `src/ExpressVpnProvider.psm1` does not exist.

- [ ] **Step 3: Extract ExpressVPN automation into the provider**

Move the UI Automation setup and private helpers from
`Switch-ExpressVpn.ps1` into the module. Replace the four display-oriented
operations with:

```powershell
function Get-VpnStatus {
    # Return state, location, and tunnel; never write output.
}
function Connect-Vpn {
    param([AllowEmptyString()][string]$Location = '', [int]$TimeoutSec = 60)
    # Empty location uses the current selection.
    # Return state, location, and changed.
}
function Disconnect-Vpn {
    param([int]$TimeoutSec = 30)
    # Return state and changed.
}
function Get-VpnLocations {
    # Return @{ locations = @(@{ name = ...; region = ... }) }.
}
```

Normalize ExpressVPN UI state strings to `connected`, `disconnected`,
`connecting`, or `unknown`. Replace timeout exits with
`New-VpnCtlException 'timeout' <message> 2`. All other selector, installation,
ambiguous-location, and no-match failures throw normally and therefore map to
exit 1. Preserve picker cleanup with `try/finally`.

- [ ] **Step 4: Run static and CLI tests**

Run the full suite.

Expected: exit 0, with provider export and no-output rules passing.

- [ ] **Step 5: Commit, open a PR, and merge**

```powershell
git add src/ExpressVpnProvider.psm1 tests/run-tests.ps1
git commit -m "refactor: isolate ExpressVPN provider"
```

Push the task branch, open a pull request, merge it after checks pass, and
update the local default branch.

### Task 4: Hotspot Shield provider module

**Files:**
- Create: `src/HotspotShieldProvider.psm1`
- Modify: `tests/run-tests.ps1`

**Interfaces:**
- Consumes: `New-VpnCtlException` from the common module.
- Produces the same four-command provider API as Task 3.
- `Connect-Vpn([string]$Location, [int]$TimeoutSec = 45)` permits an empty location.
- `Disconnect-Vpn([int]$TimeoutSec = 30)`.

- [ ] **Step 1: Add failing static provider-contract tests**

Mirror the ExpressVPN module checks for exports and absence of `Write-Host`,
`Write-Warning`, and `exit`.

- [ ] **Step 2: Run tests to verify they fail**

Run the full test suite.

Expected: failure because `src/HotspotShieldProvider.psm1` does not exist.

- [ ] **Step 3: Extract Hotspot Shield automation into the provider**

Move UI Automation setup and private helpers from
`Switch-HotspotShield.ps1`. Implement the four common operations, returning
normalized objects rather than writing display text. Preserve location `code`
and display `name` separately when item names have the form `CODE : Name`.
Map `Wait-ConnectResult` values as follows:

```powershell
switch ($result) {
    'connected' { return }
    'cant-connect' {
        throw (New-VpnCtlException -Code 'provider_failure' `
            -Message "Hotspot Shield reported that it can't connect." -ExitCode 3)
    }
    default {
        throw (New-VpnCtlException -Code 'timeout' `
            -Message "Hotspot Shield did not connect within $TimeoutSec seconds." `
            -ExitCode 2)
    }
}
```

Return `changed = $false` for already-satisfied connect/disconnect operations
and `$true` after an actual state change.

- [ ] **Step 4: Run static and CLI tests**

Run the full suite.

Expected: exit 0 and both provider contracts pass.

- [ ] **Step 5: Commit, open a PR, and merge**

```powershell
git add src/HotspotShieldProvider.psm1 tests/run-tests.ps1
git commit -m "refactor: isolate Hotspot Shield provider"
```

Push the task branch, open a pull request, merge it after checks pass, and
update the local default branch.

### Task 5: Backward-compatible wrappers

**Files:**
- Modify: `Switch-ExpressVpn.ps1`
- Modify: `Switch-HotspotShield.ps1`
- Modify: `tests/run-tests.ps1`

**Interfaces:**
- Consumes: provider operations from Tasks 3 and 4.
- Preserves: existing parameter sets `Location`, `Connect`, `Disconnect`,
  `Status`, and `List`, plus `TimeoutSec`.

- [ ] **Step 1: Add failing wrapper contract tests**

Parse each wrapper AST and assert its parameter names and parameter-set names
remain unchanged. Assert each wrapper imports its matching provider module.
Use a test provider override seam to confirm every parameter set maps to the
matching provider operation and retains human-readable output.

- [ ] **Step 2: Run tests to verify they fail**

Run the full test suite.

Expected: failure because the current scripts still contain direct automation.

- [ ] **Step 3: Replace script bodies with compatibility dispatch**

Keep the existing comment help and `param` blocks. Import the matching provider
module, dispatch the established parameter set, format returned objects in the
existing labels and prose, and catch categorized errors:

```powershell
try {
    # parameter-set dispatch and text formatting
} catch {
    $info = Get-VpnCtlErrorInfo -Exception $_.Exception
    [Console]::Error.WriteLine($info.message)
    exit $info.exitCode
}
```

Status retains `State`, `Location`, and ExpressVPN `Tunnel` lines. Locations
retain one display entry per line. Connect/disconnect retain their successful
completion statements.

- [ ] **Step 4: Run tests to verify they pass**

Run the full suite.

Expected: exit 0 with wrapper interface and dispatch tests passing.

- [ ] **Step 5: Commit, open a PR, and merge**

```powershell
git add Switch-ExpressVpn.ps1 Switch-HotspotShield.ps1 tests/run-tests.ps1
git commit -m "refactor: preserve legacy VPN script interfaces"
```

Push the task branch, open a pull request, merge it after checks pass, and
update the local default branch.

### Task 6: Documentation and final verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Documents the public command, JSON schema, exit codes, text mode, runtime
  constraints, and legacy entry points.

- [ ] **Step 1: Update README CLI examples**

Make `vpnctl.ps1` the primary documented interface. Include examples for all
four commands, location names containing spaces, `--timeout`, `--text`, and
PowerShell caller parsing:

```powershell
$result = powershell -NoProfile -File .\vpnctl.ps1 status `
    --provider expressvpn | ConvertFrom-Json
if (-not $result.ok) { throw $result.error.message }
```

Document the stable JSON envelope, command-specific `data`, exit codes
0/1/2/3/64, exact provider identifiers, one-document stdout guarantee, and
interactive-desktop limitation. Retain a compatibility section for both
`Switch-*.ps1` scripts.

- [ ] **Step 2: Run automated verification**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
git diff --check
```

Expected: tests exit 0 and `git diff --check` prints nothing.

- [ ] **Step 3: Run manual smoke checks that do not require a VPN app**

Run:

```powershell
powershell -NoProfile -File .\vpnctl.ps1 --help
powershell -NoProfile -File .\vpnctl.ps1 status --provider invalid
```

Expected: help exits 0 with usage text; invalid provider emits one JSON object
with `error.code` equal to `usage_error` and exits 64.

- [ ] **Step 4: Record integration-test limits**

In the final handoff, state explicitly that real status/connect/disconnect and
location enumeration were not exercised unless both installed, signed-in VPN
applications were available in an unlocked interactive session.

- [ ] **Step 5: Commit, open a PR, and merge**

```powershell
git add README.md
git commit -m "docs: document vpnctl automation interface"
```

Push the task branch, open a pull request, and merge it after checks pass.
