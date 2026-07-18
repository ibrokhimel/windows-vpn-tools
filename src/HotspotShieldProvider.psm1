$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$script:AE = [System.Windows.Automation.AutomationElement]
$script:TS = [System.Windows.Automation.TreeScope]

function New-HssError {
    param([string]$Code, [string]$Message, [int]$ExitCode = 1)

    if (Get-Command New-VpnCtlException -ErrorAction SilentlyContinue) {
        return New-VpnCtlException -Code $Code -Message $Message -ExitCode $ExitCode
    }

    $exception = New-Object System.Exception($Message)
    $exception.Data['VpnCtlCode'] = $Code
    $exception.Data['VpnCtlExitCode'] = $ExitCode
    return $exception
}

function Get-HssExePath {
    $candidates = Get-ChildItem 'C:\Program Files (x86)\Hotspot Shield\*\bin\hsscp.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if (-not $candidates) {
        throw (New-HssError -Code 'operational_error' `
            -Message 'Hotspot Shield does not appear to be installed (hsscp.exe not found).')
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
            $condition = New-Object System.Windows.Automation.PropertyCondition(
                $script:AE::ProcessIdProperty, $proc.Id)
            $window = $script:AE::RootElement.FindFirst($script:TS::Children, $condition)
            if ($window) { return $window }
        }

        if ($launches -lt 2) {
            Start-Process $exe | Out-Null
            $launches++
            Start-Sleep -Seconds 3
        } else {
            Start-Sleep -Milliseconds 800
        }
    }

    throw (New-HssError -Code 'operational_error' `
        -Message 'Could not find or open the Hotspot Shield window.')
}

function Find-ById {
    param($Root, [string]$Id)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        $script:AE::AutomationIdProperty, $Id)
    return $Root.FindFirst($script:TS::Descendants, $condition)
}

function Wait-ById {
    param($Root, [string]$Id, [int]$TimeoutMs = 8000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $element = Find-ById $Root $Id
        if ($element) { return $element }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-El {
    param($Element)
    $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Get-ListItems {
    param($Root)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        $script:AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    return @($Root.FindAll($script:TS::Descendants, $condition))
}

function Test-VpnConnected {
    if (Get-Process -Name hydra, wireguard -ErrorAction SilentlyContinue) { return $true }
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'HotspotShield' -and $_.Status -eq 'Up' }
    return [bool]$adapter
}

function Enter-Dashboard {
    param($Window)
    for ($i = 0; $i -lt 5; $i++) {
        $onPicker = Find-ById $Window 'SearchBox'
        $locationButton = Find-ById $Window 'btn_vl_change'
        if ($locationButton -and -not $onPicker) { return }

        $back = Find-ById $Window 'btn_back'
        if ($back) {
            Invoke-El $back
        } else {
            $dashboard = Find-ById $Window 'btn_dashboard'
            if ($dashboard) { Invoke-El $dashboard }
        }
        Start-Sleep -Milliseconds 900
    }
    throw (New-HssError -Code 'operational_error' `
        -Message 'Could not navigate to the Hotspot Shield dashboard.')
}

function Open-LocationPicker {
    param($Window)
    Enter-Dashboard $Window
    $button = Wait-ById $Window 'btn_vl_change' 5000
    if (-not $button) {
        throw (New-HssError -Code 'operational_error' `
            -Message 'Hotspot Shield location button was not found.')
    }
    Invoke-El $button
    $searchBox = Wait-ById $Window 'SearchBox' 8000
    if (-not $searchBox) {
        throw (New-HssError -Code 'operational_error' `
            -Message 'The Hotspot Shield location picker did not open.')
    }
    return $searchBox
}

function Get-SelectedLocation {
    param($Window)
    $text = Find-ById $Window 'txt_vl_selected'
    if ($text) { return $text.Current.Name }
    return $null
}

function Wait-VpnState {
    param([bool]$WantConnected, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-VpnConnected) -eq $WantConnected) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

function Test-TextVisible {
    param($Window, [string]$Pattern)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        $script:AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    foreach ($text in $Window.FindAll($script:TS::Descendants, $condition)) {
        if (-not $text.Current.IsOffscreen -and $text.Current.Name -match $Pattern) {
            return $true
        }
    }
    return $false
}

function Test-SubscriptionRestrictionText {
    param([string]$Text)
    return $Text -match '(?ix)
        \bupgrade\s+to\s+(?:an?\s+)?(?:premium|paid|higher)\b |
        \b(?:get|go)\s+premium\b |
        \bsubscribe\s+to\s+(?:unlock|access|connect|continue)\b |
        \b(?:subscription|premium|plan)\b.{0,40}\b(?:required|only|needed)\b |
        \b(?:requires?|needs?)\b.{0,40}\b(?:subscription|premium|plan|upgrade)\b
    '
}

function Test-SubscriptionRestriction {
    param($Window)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        $script:AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    foreach ($text in $Window.FindAll($script:TS::Descendants, $condition)) {
        if (-not $text.Current.IsOffscreen -and
            (Test-SubscriptionRestrictionText $text.Current.Name)) {
            return $true
        }
    }
    return $false
}

function Wait-ConnectResult {
    param($Window, [int]$Seconds, [string]$RequestedLocation)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-VpnConnected) {
            $selected = Get-SelectedLocation $Window
            if ([string]::IsNullOrWhiteSpace($RequestedLocation) -or
                (Test-HssLocationMatch $selected $RequestedLocation)) {
                return 'connected'
            }
        }
        if (Test-SubscriptionRestriction $Window) {
            return 'subscription-required'
        }
        if (Test-TextVisible $Window "Can't connect") { return 'cant-connect' }
        Start-Sleep -Milliseconds 800
    }
    return 'timeout'
}

function Test-HssLocationMatch {
    param([string]$Selected, [string]$Requested)
    if ($Selected -ieq $Requested) { return $true }
    $selectedLocation = ConvertTo-HssLocation $Selected
    $requestedLocation = ConvertTo-HssLocation $Requested
    return ($selectedLocation.name -ieq $requestedLocation.name) -or
        ($selectedLocation.PSObject.Properties['code'] -and
            $selectedLocation.code -ieq $Requested) -or
        ($requestedLocation.PSObject.Properties['code'] -and
            $requestedLocation.code -ieq $Selected)
}

function Assert-ConnectResult {
    param([string]$Result, [int]$TimeoutSec)
    switch ($Result) {
        'connected' { return }
        'subscription-required' {
            throw (New-HssError -Code 'subscription_required' `
                -Message 'Hotspot Shield reported that this connection requires a subscription or plan upgrade.' -ExitCode 4)
        }
        'cant-connect' {
            throw (New-HssError -Code 'provider_failure' `
                -Message "Hotspot Shield reported that it can't connect." -ExitCode 3)
        }
        default {
            throw (New-HssError -Code 'timeout' `
                -Message "Hotspot Shield did not connect within $TimeoutSec seconds." -ExitCode 2)
        }
    }
}

function ConvertTo-HssLocation {
    param([string]$ItemName)
    $parts = $ItemName -split ' : ', 2
    if ($parts.Count -eq 2) {
        return [pscustomobject][ordered]@{ name = $parts[1]; code = $parts[0] }
    }
    return [pscustomobject][ordered]@{ name = $ItemName }
}

function Clear-LocationSearch {
    param($SearchBox)
    $pattern = $SearchBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($pattern.Current.Value) {
        $pattern.SetValue('')
        Start-Sleep -Milliseconds 1000
    }
}

function Get-LocationItemNames {
    param($Window)
    $names = @()
    foreach ($listId in 'CurrentList', 'RecentList', 'CountriesList') {
        $list = Find-ById $Window $listId
        if (-not $list) { continue }
        foreach ($item in Get-ListItems $list) {
            $names += $item.Current.Name
        }
    }
    return $names
}

function Find-ExactItem {
    param($Items, [string]$Query)
    foreach ($item in $Items) {
        $location = ConvertTo-HssLocation $item.Current.Name
        if (($location.name -ieq $Query) -or
            ($location.PSObject.Properties['code'] -and $location.code -ieq $Query)) {
            return $item
        }
    }
    return $null
}

function Select-HssLocation {
    param($Window, [string]$Query)
    $searchBox = Open-LocationPicker $Window
    $target = Find-ExactItem (Get-ListItems $Window) $Query

    if (-not $target) {
        $pattern = $searchBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $pattern.SetValue($Query)
        $deadline = (Get-Date).AddSeconds(8)
        $items = @()
        do {
            Start-Sleep -Milliseconds 500
            $items = Get-ListItems $Window
        } while ($items.Count -eq 0 -and (Get-Date) -lt $deadline)

        if ($items.Count -eq 0) {
            Enter-Dashboard $Window
            throw (New-HssError -Code 'location_not_found' `
                -Message "No Hotspot Shield location matches '$Query'.")
        }

        $target = Find-ExactItem $items $Query
        if (-not $target -and $items.Count -eq 1) { $target = $items[0] }
        if (-not $target) {
            Enter-Dashboard $Window
            throw (New-HssError -Code 'ambiguous_location' `
                -Message "Multiple Hotspot Shield locations match '$Query'.")
        }
    }

    try {
        $target.GetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Milliseconds 500
    } catch {
        # Some app versions do not expose SelectionItemPattern on this item.
    }

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        $script:AE::AutomationIdProperty, 'ConnectButton')
    $connectButton = $target.FindFirst($script:TS::Descendants, $condition)
    if (-not $connectButton) {
        Enter-Dashboard $Window
        throw (New-HssError -Code 'operational_error' `
            -Message "The Connect button for '$($target.Current.Name)' is unavailable.")
    }
    Invoke-El $connectButton
    return $target.Current.Name
}

function Get-VpnStatus {
    $window = Get-HssWindow
    Enter-Dashboard $window
    $state = if (Test-VpnConnected) { 'connected' } else { 'disconnected' }
    return [pscustomobject][ordered]@{
        state = $state
        location = Get-SelectedLocation $window
    }
}

function Connect-Vpn {
    param([string]$Location, [int]$TimeoutSec = 45)

    $window = Get-HssWindow
    Enter-Dashboard $window
    $isConnected = Test-VpnConnected
    $selectedLocation = Get-SelectedLocation $window
    if ($isConnected -and
        ([string]::IsNullOrWhiteSpace($Location) -or $selectedLocation -ieq $Location)) {
        return [pscustomobject][ordered]@{
            state = 'connected'
            location = $selectedLocation
            changed = $false
        }
    }

    if ([string]::IsNullOrWhiteSpace($Location)) {
        $button = Find-ById $window 'btn_connect'
        if (-not $button) {
            throw (New-HssError -Code 'operational_error' `
                -Message 'Hotspot Shield connect button was not found.')
        }
        Invoke-El $button
    } else {
        $selectedTarget = Select-HssLocation $window $Location
        if (-not [string]::IsNullOrWhiteSpace($selectedTarget)) {
            $Location = $selectedTarget
        }
    }

    Assert-ConnectResult (Wait-ConnectResult $window $TimeoutSec $Location) $TimeoutSec
    return [pscustomobject][ordered]@{
        state = 'connected'
        location = Get-SelectedLocation $window
        changed = $true
    }
}

function Disconnect-Vpn {
    param([int]$TimeoutSec = 30)

    $window = Get-HssWindow
    Enter-Dashboard $window
    if (-not (Test-VpnConnected)) {
        return [pscustomobject][ordered]@{
            state = 'disconnected'
            changed = $false
        }
    }

    $button = Find-ById $window 'btn_connect'
    if (-not $button) {
        throw (New-HssError -Code 'operational_error' `
            -Message 'Hotspot Shield disconnect button was not found.')
    }
    Invoke-El $button
    if (-not (Wait-VpnState $false $TimeoutSec)) {
        throw (New-HssError -Code 'timeout' `
            -Message "Hotspot Shield did not disconnect within $TimeoutSec seconds." -ExitCode 2)
    }

    return [pscustomobject][ordered]@{
        state = 'disconnected'
        changed = $true
    }
}

function Get-VpnLocations {
    $window = Get-HssWindow
    $searchBox = Open-LocationPicker $window
    Clear-LocationSearch $searchBox
    $locations = @(Get-LocationItemNames $window | ForEach-Object {
        ConvertTo-HssLocation $_
    })
    Enter-Dashboard $window
    return [pscustomobject][ordered]@{ locations = $locations }
}

Export-ModuleMember -Function Get-VpnStatus, Connect-Vpn, Disconnect-Vpn, Get-VpnLocations
