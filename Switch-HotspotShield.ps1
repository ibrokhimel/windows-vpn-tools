<#
.SYNOPSIS
    Control the Hotspot Shield VPN app from the command line.

.DESCRIPTION
    Hotspot Shield has no official CLI or API on Windows, so this script drives
    the real app (hsscp.exe) through Microsoft UI Automation, using the app's
    stable AutomationIds (btn_connect, btn_vl_change, SearchBox, ConnectButton...).

    Requires an interactive desktop session (will not work on a locked screen
    or over a non-interactive service). Works even if the app window is
    behind other windows; it does not need keyboard/mouse focus, except that
    the app window must exist (it is summoned from the tray automatically).

    Exit codes: 0 success, 1 operational error, 2 timeout, 3 explicit
    connection failure, and 4 when the provider explicitly displays a
    subscription or plan restriction.

.EXAMPLE
    .\Switch-Vpn.ps1 -Status
.EXAMPLE
    .\Switch-Vpn.ps1 -ListLocations
.EXAMPLE
    .\Switch-Vpn.ps1 -Location "United Kingdom"    # country name
.EXAMPLE
    .\Switch-Vpn.ps1 -Location "New York"          # city name
.EXAMPLE
    .\Switch-Vpn.ps1 -Connect
.EXAMPLE
    .\Switch-Vpn.ps1 -Disconnect
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    # Country or city to connect to (e.g. "Germany", "Miami", or a code like "USNYC")
    [Parameter(ParameterSetName = 'Location', Mandatory = $true, Position = 0)]
    [string]$Location,

    # Connect to the currently selected location
    [Parameter(ParameterSetName = 'Connect', Mandatory = $true)]
    [switch]$Connect,

    # Disconnect the VPN
    [Parameter(ParameterSetName = 'Disconnect', Mandatory = $true)]
    [switch]$Disconnect,

    # Show connection state and selected location (default action)
    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    # List all available countries and quick-access entries
    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$ListLocations,

    # Seconds to wait for the VPN tunnel to come up/down
    [int]$TimeoutSec = 45
)

$ErrorActionPreference = 'Stop'

$commonModule = Join-Path $PSScriptRoot 'src\VpnCtl.Common.psm1'
$providerModule = Join-Path $PSScriptRoot 'src\HotspotShieldProvider.psm1'
if ($env:VPNCTL_PROVIDER_MODULE) {
    $providerModule = $env:VPNCTL_PROVIDER_MODULE
}

try {
    Import-Module $commonModule -Force
    Import-Module $providerModule -Force

    switch ($PSCmdlet.ParameterSetName) {
        'Location' {
            $result = Connect-Vpn -Location $Location -TimeoutSec $TimeoutSec
            [Console]::Out.WriteLine(
                "Connected. Selected location: $($result.location)")
        }
        'Connect' {
            $result = Connect-Vpn -Location '' -TimeoutSec $TimeoutSec
            if ($result.changed) {
                [Console]::Out.WriteLine('Connected.')
            } else {
                [Console]::Out.WriteLine("Already connected ($($result.location)).")
            }
        }
        'Disconnect' {
            $result = Disconnect-Vpn -TimeoutSec $TimeoutSec
            if ($result.changed) {
                [Console]::Out.WriteLine('Disconnected.')
            } else {
                [Console]::Out.WriteLine('Already disconnected.')
            }
        }
        'List' {
            $result = Get-VpnLocations
            foreach ($item in $result.locations) {
                if ($item.PSObject.Properties['code'] -and $item.code) {
                    [Console]::Out.WriteLine("$($item.code) : $($item.name)")
                } else {
                    [Console]::Out.WriteLine($item.name)
                }
            }
        }
        default {
            $result = Get-VpnStatus
            $displayState = switch ($result.state) {
                'connected' { 'Connected' }
                'disconnected' { 'Disconnected' }
                default { $result.state }
            }
            [Console]::Out.WriteLine(('State    : {0}' -f $displayState))
            [Console]::Out.WriteLine(('Location : {0}' -f $result.location))
        }
    }
} catch {
    $info = Get-VpnCtlErrorInfo -Exception $_.Exception
    [Console]::Error.WriteLine($info.message)
    exit $info.exitCode
}
