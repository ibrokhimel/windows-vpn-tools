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
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class VpnWin32 { [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l); }'

$Script:AE = [System.Windows.Automation.AutomationElement]
$Script:TS = [System.Windows.Automation.TreeScope]

$Script:ExePath = 'C:\Program Files (x86)\ExpressVPN\expressvpn-ui\ExpressVPN.exe'

function Get-EvpnWindow {
    if (-not (Test-Path $ExePath)) { throw 'ExpressVPN does not appear to be installed.' }
    $launches = 0
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process -Name ExpressVPN -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($proc) {
            $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id)
            $win = $AE::RootElement.FindFirst($TS::Children, $cond)
            if ($win) { return $win }
        }
        if ($launches -lt 2) {
            Start-Process $ExePath | Out-Null
            $launches++
            Start-Sleep -Seconds 4
        } else {
            Start-Sleep -Milliseconds 800
        }
    }
    throw 'Could not find or open the ExpressVPN window.'
}

function Find-ById([System.Windows.Automation.AutomationElement]$Root, [string]$Id) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $Id)
    return $Root.FindFirst($TS::Descendants, $cond)
}

function Wait-ById([System.Windows.Automation.AutomationElement]$Root, [string]$Id, [int]$TimeoutMs = 8000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $el = Find-ById $Root $Id
        if ($el) { return $el }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-El([System.Windows.Automation.AutomationElement]$El) {
    $El.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

# The app's own state text: 'Not Connected', 'Connecting...', 'Connected', ...
function Get-VpnStateText([System.Windows.Automation.AutomationElement]$Win) {
    $el = Find-ById $Win 'CurrentVPNState'
    if ($el) { return $el.Current.Name.Trim() }
    return '(unknown)'
}

function Get-VpnButtonLabel([System.Windows.Automation.AutomationElement]$Win) {
    $el = Find-ById $Win 'VpnButton'
    if ($el) { return $el.Current.Name.Trim() }
    return ''
}

function Test-TunnelUp {
    $tun = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'ExpressVPN|OpenVPN.*ExpressVPN' -and $_.Status -eq 'Up' }
    return [bool]$tun
}

function Wait-ForState([System.Windows.Automation.AutomationElement]$Win, [string]$Pattern, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VpnStateText $Win) -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 800
    }
    return $false
}

function Close-Picker([System.Windows.Automation.AutomationElement]$Win) {
    $pw = Find-ById $Win 'LocationPickerWindow'
    if ($pw) {
        try { $pw.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } catch { }
        Start-Sleep -Milliseconds 500
    }
}

function Open-Picker([System.Windows.Automation.AutomationElement]$Win) {
    $sb = Find-ById $Win 'SearchBox'
    if ($sb) { return $sb }   # already open
    $btn = Wait-ById $Win 'SelectLocationButton' 5000
    if (-not $btn) { throw 'Location button (SelectLocationButton) not found - the app UI may have changed, or the app is mid-connection.' }
    Invoke-El $btn
    $sb = Wait-ById $Win 'SearchBox' 8000
    if (-not $sb) { throw 'The location picker did not open.' }
    return $sb
}

function Get-SelectButtons([System.Windows.Automation.AutomationElement]$Win) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $out = @()
    foreach ($b in $Win.FindAll($TS::Descendants, $cond)) {
        if ($b.Current.Name -like 'Select Location*') { $out += $b }
    }
    return $out
}

# The picker's per-row "Select Location" buttons only act when their row is in
# hover state. A WM_MOUSEMOVE posted to the picker window at the row's client
# coordinates produces that state without moving the real cursor or needing
# the window in the foreground.
function Send-HoverTo([System.Windows.Automation.AutomationElement]$Win, [System.Windows.Automation.AutomationElement]$El) {
    $pw = Find-ById $Win 'LocationPickerWindow'
    if (-not $pw) { return }
    $h = [IntPtr]$pw.Current.NativeWindowHandle
    if ($h -eq [IntPtr]::Zero) { return }
    $uw = $pw.Current.BoundingRectangle
    $er = $El.Current.BoundingRectangle
    $rx = [int]($er.X - $uw.X + [Math]::Min(100, [int]($er.Width / 2)))
    $ry = [int]($er.Y - $uw.Y + [int]($er.Height / 2))
    $lp = [IntPtr](($ry -shl 16) -bor ($rx -band 0xFFFF))
    [VpnWin32]::PostMessage($h, 0x200, [IntPtr]::Zero, $lp) | Out-Null   # WM_MOUSEMOVE
    Start-Sleep -Milliseconds 500
}

function Show-Status {
    $win = Get-EvpnWindow
    $state = Get-VpnStateText $win
    $label = Get-VpnButtonLabel $win
    $target = $label -replace '^(Connect to|Connected to|Disconnect from|Cancel connecting to)\s*', '' -replace '^Disconnect$', ''
    Write-Host ("State    : {0}" -f $state)
    if ($target) { Write-Host ("Location : {0}" -f $target) }
    Write-Host ("Tunnel   : {0}" -f $(if (Test-TunnelUp) { 'up' } else { 'down' }))
}

function Show-Locations {
    $win = Get-EvpnWindow
    $sb = Open-Picker $win
    $vp = $sb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($vp.Current.Value) { $vp.SetValue(''); Start-Sleep -Milliseconds 800 }

    # Switch to the All Locations tab so more entries are realized
    $all = Find-ById $win 'AllTab'
    if ($all) {
        try { $all.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch { }
        Start-Sleep -Milliseconds 1200
    }
    $icond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TreeItem)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Tree)
    foreach ($tree in $win.FindAll($TS::Descendants, $cond)) {
        # Top level of the All tab is region groups. Expand and read one at a
        # time - the list is virtualized, so children only exist while their
        # region is the expanded one.
        foreach ($region in $tree.FindAll($TS::Children, $icond)) {
            Write-Host ("== {0} ==" -f $region.Current.Name)
            try {
                $ec = $region.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                $ec.Expand()
                Start-Sleep -Milliseconds 700
                foreach ($item in $region.FindAll($TS::Descendants, $icond)) {
                    Write-Host ("  {0}" -f $item.Current.Name)
                }
                $ec.Collapse()
                Start-Sleep -Milliseconds 300
            } catch {
                Write-Host '  (could not expand)'
            }
        }
    }
    Write-Host "`nNote: long lists are virtualized - not every country may be shown."
    Write-Host "Tip: -Location accepts any city or country, e.g. -Location 'USA - Miami' or -Location Japan."
    Close-Picker $win
}

function Connect-ToLocation([string]$Query) {
    $win = Get-EvpnWindow
    $sb = Open-Picker $win

    # Exact match among already-visible entries (smart/recent/recommended) first
    $target = $null
    foreach ($b in Get-SelectButtons $win) {
        if ($b.Current.AutomationId -ieq $Query) { $target = $b; break }
    }

    if (-not $target) {
        $vp = $sb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $vp.SetValue($Query)
        $deadline = (Get-Date).AddSeconds(8)
        $buttons = @()
        do {
            Start-Sleep -Milliseconds 500
            $buttons = @(Get-SelectButtons $win)
        } while ($buttons.Count -eq 0 -and (Get-Date) -lt $deadline)

        if ($buttons.Count -eq 0) {
            Close-Picker $win
            throw "No location matches '$Query'. Try -ListLocations, or search terms like 'USA - Miami'."
        }
        foreach ($b in $buttons) {
            if ($b.Current.AutomationId -ieq $Query) { $target = $b; break }
        }
        if (-not $target) {
            if ($buttons.Count -eq 1) {
                $target = $buttons[0]
            } else {
                $names = ($buttons | ForEach-Object { '  ' + $_.Current.AutomationId }) -join "`n"
                Close-Picker $win
                throw "Multiple locations match '$Query'. Be more specific:`n$names"
            }
        }
    }

    $chosen = $target.Current.AutomationId
    Write-Host "Connecting to $chosen ..."

    Send-HoverTo $win $target
    # Re-find the button after hovering; WPF may re-template the row
    foreach ($b in Get-SelectButtons $win) {
        if ($b.Current.AutomationId -ieq $chosen) { $target = $b; break }
    }
    Invoke-El $target

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $state = Get-VpnStateText $win
        $label = Get-VpnButtonLabel $win
        if ($state -match '^Connected' -and $label -match [regex]::Escape($chosen)) {
            Write-Host ("Connected to {0}." -f $chosen)
            Close-Picker $win
            return
        }
        Start-Sleep -Milliseconds 800
    }
    $state = Get-VpnStateText $win
    Write-Warning "Did not reach Connected state within $TimeoutSec seconds (current state: $state). Check the ExpressVPN window."
    exit 2
}

function Connect-Current {
    $win = Get-EvpnWindow
    $state = Get-VpnStateText $win
    if ($state -match '^Connected') {
        Write-Host "Already connected ($(Get-VpnButtonLabel $win))."
        return
    }
    $btn = Find-ById $win 'VpnButton'
    if (-not $btn) { throw 'VpnButton not found - the app UI may have changed.' }
    Write-Host ("{0} ..." -f $btn.Current.Name)
    Invoke-El $btn
    if (Wait-ForState $win '^Connected' $TimeoutSec) {
        Write-Host 'Connected.'
    } else {
        $state = Get-VpnStateText $win
        Write-Warning "Did not reach Connected state within $TimeoutSec seconds (current state: $state). Check the ExpressVPN window."
        exit 2
    }
}

function Disconnect-Vpn {
    $win = Get-EvpnWindow
    $state = Get-VpnStateText $win
    if ($state -match 'Not Connected') {
        Write-Host 'Already disconnected.'
        return
    }
    $btn = Find-ById $win 'VpnButton'
    if (-not $btn) { throw 'VpnButton not found - the app UI may have changed.' }
    Write-Host 'Disconnecting ...'
    Invoke-El $btn
    if (Wait-ForState $win 'Not Connected' 30) {
        Write-Host 'Disconnected.'
    } else {
        Write-Warning "Still not disconnected after 30 seconds (state: $(Get-VpnStateText $win)). Check the ExpressVPN window."
        exit 2
    }
}

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Location'   { Connect-ToLocation $Location }
        'Connect'    { Connect-Current }
        'Disconnect' { Disconnect-Vpn }
        'List'       { Show-Locations }
        default      { Show-Status }
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
