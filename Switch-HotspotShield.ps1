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
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$Script:AE  = [System.Windows.Automation.AutomationElement]
$Script:TS  = [System.Windows.Automation.TreeScope]
$Script:True_ = [System.Windows.Automation.Condition]::TrueCondition

function Get-HssExePath {
    $candidates = Get-ChildItem 'C:\Program Files (x86)\Hotspot Shield\*\bin\hsscp.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if (-not $candidates) {
        throw 'Hotspot Shield does not appear to be installed (hsscp.exe not found).'
    }
    return $candidates[0].FullName
}

function Get-HssWindow {
    $exe = Get-HssExePath
    $launches = 0
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process -Name hsscp -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id)
            $win = $AE::RootElement.FindFirst($TS::Children, $cond)
            if ($win) { return $win }
        }
        # Not running, or running with no window (minimized to tray):
        # launching the exe starts it / summons the existing instance's window.
        if ($launches -lt 2) {
            Start-Process $exe | Out-Null
            $launches++
            Start-Sleep -Seconds 3
        } else {
            Start-Sleep -Milliseconds 800
        }
    }
    throw 'Could not find or open the Hotspot Shield window.'
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

function Get-ListItems([System.Windows.Automation.AutomationElement]$Root) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    return @($Root.FindAll($TS::Descendants, $cond))
}

function Test-VpnConnected {
    # Tunnel engine (Hydra or WireGuard) runs only while connected/connecting
    if (Get-Process -Name hydra, wireguard -ErrorAction SilentlyContinue) { return $true }
    $tap = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'HotspotShield' -and $_.Status -eq 'Up' }
    return [bool]$tap
}

function Enter-Dashboard([System.Windows.Automation.AutomationElement]$Win) {
    for ($i = 0; $i -lt 5; $i++) {
        $onPicker  = Find-ById $Win 'SearchBox'
        $vlChange  = Find-ById $Win 'btn_vl_change'
        if ($vlChange -and -not $onPicker) { return }
        $back = Find-ById $Win 'btn_back'
        if ($back) {
            Invoke-El $back
        } else {
            $dash = Find-ById $Win 'btn_dashboard'
            if ($dash) { Invoke-El $dash }
        }
        Start-Sleep -Milliseconds 900
    }
    throw 'Could not navigate to the Hotspot Shield dashboard (unexpected screen or dialog open).'
}

function Open-LocationPicker([System.Windows.Automation.AutomationElement]$Win) {
    Enter-Dashboard $Win
    $btn = Wait-ById $Win 'btn_vl_change' 5000
    if (-not $btn) { throw "Location button (btn_vl_change) not found - the app UI may have changed." }
    Invoke-El $btn
    $sb = Wait-ById $Win 'SearchBox' 8000
    if (-not $sb) { throw 'The location picker did not open.' }
    return $sb
}

function Get-SelectedLocation([System.Windows.Automation.AutomationElement]$Win) {
    $txt = Find-ById $Win 'txt_vl_selected'
    if ($txt) { return $txt.Current.Name }
    return '(unknown)'
}

function Wait-VpnState([bool]$WantConnected, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-VpnConnected) -eq $WantConnected) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

function Test-TextVisible([System.Windows.Automation.AutomationElement]$Win, [string]$Pattern) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    foreach ($t in $Win.FindAll($TS::Descendants, $cond)) {
        if (-not $t.Current.IsOffscreen -and $t.Current.Name -match $Pattern) { return $true }
    }
    return $false
}

# Returns 'connected', 'cant-connect', or 'timeout'. The app shows a transient
# "Can't connect" toast when its own connection attempt fails.
function Wait-ConnectResult([System.Windows.Automation.AutomationElement]$Win, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-VpnConnected) { return 'connected' }
        if (Test-TextVisible $Win "Can't connect") { return 'cant-connect' }
        Start-Sleep -Milliseconds 800
    }
    return 'timeout'
}

function Exit-ConnectFailure([string]$Result, [int]$Seconds) {
    if ($Result -eq 'cant-connect') {
        Write-Warning "Hotspot Shield reported ""Can't connect"" - the app itself failed to establish the tunnel (this is not an automation error; the same happens when clicking manually). Try another location, check your internet connection, or restart the Hotspot Shield service."
        exit 3
    }
    Write-Warning "VPN tunnel did not come up within $Seconds seconds. Check the Hotspot Shield window (a sign-in or upgrade prompt may be blocking it)."
    exit 2
}

function Show-Status {
    $win = Get-HssWindow
    Enter-Dashboard $win
    $loc = Get-SelectedLocation $win
    if (Test-VpnConnected) { $state = 'Connected' } else { $state = 'Disconnected' }
    Write-Host ("State    : {0}" -f $state)
    Write-Host ("Location : {0}" -f $loc)
}

function Show-Locations {
    $win = Get-HssWindow
    $sb = Open-LocationPicker $win
    $vp = $sb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($vp.Current.Value) { $vp.SetValue(''); Start-Sleep -Milliseconds 1000 }

    foreach ($listId in 'CurrentList', 'RecentList', 'CountriesList') {
        $list = Find-ById $win $listId
        if (-not $list) { continue }
        switch ($listId) {
            'CurrentList'   { Write-Host "== Current selection ==" }
            'RecentList'    { Write-Host "`n== Quick access ==" }
            'CountriesList' { Write-Host "`n== All locations ==" }
        }
        foreach ($item in Get-ListItems $list) {
            Write-Host ("  {0}" -f $item.Current.Name)
        }
    }
    Write-Host "`nTip: -Location accepts a country name, a city name (e.g. 'Miami'), or a code (e.g. 'USNYC')."
    Enter-Dashboard $win
}

function Find-ExactItem($Items, [string]$Query) {
    # Item names look like "USHOU : Houston"; match display name or code.
    foreach ($item in $Items) {
        $parts = $item.Current.Name -split ' : ', 2
        if ($parts.Count -eq 2) { $code = $parts[0]; $disp = $parts[1] } else { $code = ''; $disp = $parts[0] }
        if (($disp -ieq $Query) -or ($code -ieq $Query)) { return $item }
    }
    return $null
}

function Connect-ToLocation([string]$Query) {
    $win = Get-HssWindow
    $sb = Open-LocationPicker $win

    # Quick-access entries ("Auto", "Streaming") and the current city only exist
    # in the unfiltered view - the search box filters countries/cities only.
    $target = Find-ExactItem (Get-ListItems $win) $Query

    if (-not $target) {
        $vp = $sb.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $vp.SetValue($Query)

        # Wait for the filtered result list
        $deadline = (Get-Date).AddSeconds(8)
        $items = @()
        do {
            Start-Sleep -Milliseconds 500
            $items = Get-ListItems $win
        } while ($items.Count -eq 0 -and (Get-Date) -lt $deadline)

        if ($items.Count -eq 0) {
            Enter-Dashboard $win
            throw "No location matches '$Query'. Try -ListLocations to see what is available."
        }

        $target = Find-ExactItem $items $Query
        if (-not $target) {
            if ($items.Count -eq 1) {
                $target = $items[0]
            } else {
                $names = ($items | ForEach-Object { '  ' + $_.Current.Name }) -join "`n"
                Enter-Dashboard $win
                throw "Multiple locations match '$Query'. Be more specific:`n$names"
            }
        }
    }

    $chosen = $target.Current.Name
    try {
        $target.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Milliseconds 500
    } catch { }

    $btnCond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'ConnectButton')
    $connectBtn = $target.FindFirst($TS::Descendants, $btnCond)
    if (-not $connectBtn) {
        Enter-Dashboard $win
        throw "Found '$chosen' but its Connect button is not available."
    }

    Write-Host "Connecting to $chosen ..."
    Invoke-El $connectBtn

    $result = Wait-ConnectResult $win $TimeoutSec
    if ($result -eq 'connected') {
        Start-Sleep -Seconds 2
        Write-Host ("Connected. Selected location: {0}" -f (Get-SelectedLocation $win))
    } else {
        Exit-ConnectFailure $result $TimeoutSec
    }
}

function Connect-Current {
    $win = Get-HssWindow
    Enter-Dashboard $win
    if (Test-VpnConnected) {
        Write-Host ("Already connected ({0})." -f (Get-SelectedLocation $win))
        return
    }
    $btn = Find-ById $win 'btn_connect'
    if (-not $btn) { throw 'Connect button (btn_connect) not found - the app UI may have changed.' }
    Write-Host ("Connecting to {0} ..." -f (Get-SelectedLocation $win))
    Invoke-El $btn
    $result = Wait-ConnectResult $win $TimeoutSec
    if ($result -eq 'connected') {
        Write-Host 'Connected.'
    } else {
        Exit-ConnectFailure $result $TimeoutSec
    }
}

function Disconnect-Vpn {
    $win = Get-HssWindow
    Enter-Dashboard $win
    if (-not (Test-VpnConnected)) {
        Write-Host 'Already disconnected.'
        return
    }
    $btn = Find-ById $win 'btn_connect'
    if (-not $btn) { throw 'Connect/disconnect button (btn_connect) not found - the app UI may have changed.' }
    Write-Host 'Disconnecting ...'
    Invoke-El $btn
    if (Wait-VpnState $false 30) {
        Write-Host 'Disconnected.'
    } else {
        Write-Warning 'VPN still appears to be up after 30 seconds. Check the Hotspot Shield window.'
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
