<#
.SYNOPSIS
    Control the ExpressVPN app from the command line.

.DESCRIPTION
    ExpressVPN 12.x on Windows has no working CLI (ExpressVPN.CLI.exe is an
    internal gRPC client that produces no console output), so this script
    drives the app (ExpressVPN.exe) through Microsoft UI Automation using its
    stable WPF AutomationIds (VpnButton, CurrentVPNState, SelectLocationButton,
    SearchBox, "Select Location::" buttons).

    Requires an interactive desktop session (will not work on a locked screen).
    Does not need the window to be focused or visible on top.

.EXAMPLE
    .\Switch-ExpressVpn.ps1 -Status
.EXAMPLE
    .\Switch-ExpressVpn.ps1 -ListLocations
.EXAMPLE
    .\Switch-ExpressVpn.ps1 -Location "Germany"            # country
.EXAMPLE
    .\Switch-ExpressVpn.ps1 -Location "USA - San Francisco" # specific city
.EXAMPLE
    .\Switch-ExpressVpn.ps1 -Connect                        # last/selected location
.EXAMPLE
    .\Switch-ExpressVpn.ps1 -Disconnect
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    # Country or city to connect to (e.g. "Germany", "San Francisco", "Smart Location")
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

    # List available locations (as shown in the picker)
    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$ListLocations,

    # Seconds to wait for the VPN to connect/disconnect
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = 'Stop'

$commonModule = Join-Path $PSScriptRoot 'src\VpnCtl.Common.psm1'
$providerModule = Join-Path $PSScriptRoot 'src\ExpressVpnProvider.psm1'
if ($env:VPNCTL_EXPRESSVPN_PROVIDER_MODULE) {
    $providerModule = $env:VPNCTL_EXPRESSVPN_PROVIDER_MODULE
}

Import-Module $commonModule -Force
Import-Module $providerModule -Force

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Location' {
            $result = Connect-Vpn -Location $Location -TimeoutSec $TimeoutSec
            if ($result.changed) {
                Write-Output ("Connected to {0}." -f $result.location)
            } else {
                Write-Output ("Already connected to {0}." -f $result.location)
            }
        }
        'Connect' {
            $result = Connect-Vpn -Location '' -TimeoutSec $TimeoutSec
            if ($result.changed) {
                Write-Output 'Connected.'
            } else {
                Write-Output ("Already connected to {0}." -f $result.location)
            }
        }
        'Disconnect' {
            $result = Disconnect-Vpn -TimeoutSec $TimeoutSec
            if ($result.changed) {
                Write-Output 'Disconnected.'
            } else {
                Write-Output 'Already disconnected.'
            }
        }
        'List' {
            $result = Get-VpnLocations
            foreach ($item in $result.locations) {
                Write-Output $item.name
            }
        }
        default {
            $result = Get-VpnStatus
            Write-Output ("State    : {0}" -f $result.state)
            if ($result.location) {
                Write-Output ("Location : {0}" -f $result.location)
            }
            Write-Output ("Tunnel   : {0}" -f $result.tunnel)
        }
    }
} catch {
    $info = Get-VpnCtlErrorInfo -Exception $_.Exception
    [Console]::Error.WriteLine($info.message)
    exit $info.exitCode
}
