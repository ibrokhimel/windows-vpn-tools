$ErrorActionPreference = 'Stop'

$commonModule = Join-Path $PSScriptRoot 'VpnCtl.Common.psm1'
if (Test-Path -LiteralPath $commonModule) {
    Import-Module $commonModule -Force
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (-not ('VpnCtlExpressWin32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VpnCtlExpressWin32 {
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@
}

$script:AE = [System.Windows.Automation.AutomationElement]
$script:TS = [System.Windows.Automation.TreeScope]
$script:ExePath = 'C:\Program Files (x86)\ExpressVPN\expressvpn-ui\ExpressVPN.exe'

function Get-EvpnWindow {
    if (-not (Test-Path -LiteralPath $script:ExePath)) {
        throw 'ExpressVPN does not appear to be installed.'
    }

    $launches = 0
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $process = Get-Process -Name ExpressVPN -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1
        if ($process) {
            $condition = New-Object System.Windows.Automation.PropertyCondition(
                $script:AE::ProcessIdProperty,
                $process.Id
            )
            $window = $script:AE::RootElement.FindFirst($script:TS::Children, $condition)
            if ($window) {
                return $window
            }
        }

        if ($launches -lt 2) {
            Start-Process $script:ExePath | Out-Null
            $launches++
            Start-Sleep -Seconds 4
        } else {
            Start-Sleep -Milliseconds 800
        }
    }

    throw 'Could not find or open the ExpressVPN window.'
}

function Find-ById {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Id
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        $script:AE::AutomationIdProperty,
        $Id
    )
    return $Root.FindFirst($script:TS::Descendants, $condition)
}

function Wait-ById {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Id,
        [int]$TimeoutMs = 8000
    )

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $element = Find-ById $Root $Id
        if ($element) {
            return $element
        }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-Element {
    param([System.Windows.Automation.AutomationElement]$Element)

    $Element.GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern
    ).Invoke()
}

function Get-VpnStateText {
    param([System.Windows.Automation.AutomationElement]$Window)

    $element = Find-ById $Window 'CurrentVPNState'
    if ($element) {
        return $element.Current.Name.Trim()
    }
    return ''
}

function ConvertTo-NormalizedState {
    param([string]$StateText)

    if ($StateText -match '^Not Connected') {
        return 'disconnected'
    }
    if ($StateText -match '^Connected') {
        return 'connected'
    }
    if ($StateText -match '^Connecting') {
        return 'connecting'
    }
    return 'unknown'
}

function Get-VpnButtonLabel {
    param([System.Windows.Automation.AutomationElement]$Window)

    $element = Find-ById $Window 'VpnButton'
    if ($element) {
        return $element.Current.Name.Trim()
    }
    return ''
}

function Get-SelectedLocation {
    param([System.Windows.Automation.AutomationElement]$Window)

    $label = Get-VpnButtonLabel $Window
    $location = $label `
        -replace '^(Connect to|Connected to|Disconnect from|Cancel connecting to)\s*', '' `
        -replace '^Disconnect$', ''
    return $location.Trim()
}

function Test-TunnelUp {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceDescription -match 'ExpressVPN|OpenVPN.*ExpressVPN' -and
            $_.Status -eq 'Up'
        } |
        Select-Object -First 1
    return [bool]$adapter
}

function Wait-ForState {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$Pattern,
        [int]$Seconds
    )

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VpnStateText $Window) -match $Pattern) {
            return $true
        }
        Start-Sleep -Milliseconds 800
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
        $script:AE::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text
    )
    foreach ($text in $Window.FindAll($script:TS::Descendants, $condition)) {
        if (-not $text.Current.IsOffscreen -and
            (Test-SubscriptionRestrictionText $text.Current.Name)) {
            return $true
        }
    }
    return $false
}

function New-SubscriptionError {
    $message = 'ExpressVPN reported that this connection requires a subscription or plan upgrade.'
    if (Get-Command New-VpnCtlException -ErrorAction SilentlyContinue) {
        return New-VpnCtlException -Code 'subscription_required' -Message $message -ExitCode 4
    }
    $exception = New-Object -TypeName System.Exception -ArgumentList $message
    $exception.Data['VpnCtlCode'] = 'subscription_required'
    $exception.Data['VpnCtlExitCode'] = 4
    return $exception
}

function Close-Picker {
    param([System.Windows.Automation.AutomationElement]$Window)

    $picker = Find-ById $Window 'LocationPickerWindow'
    if ($picker) {
        try {
            $picker.GetCurrentPattern(
                [System.Windows.Automation.WindowPattern]::Pattern
            ).Close()
        } catch {
        }
        Start-Sleep -Milliseconds 500
    }
}

function Open-Picker {
    param([System.Windows.Automation.AutomationElement]$Window)

    $searchBox = Find-ById $Window 'SearchBox'
    if ($searchBox) {
        return $searchBox
    }

    $button = Wait-ById $Window 'SelectLocationButton' 5000
    if (-not $button) {
        throw 'Location button (SelectLocationButton) not found - the app UI may have changed, or the app is mid-connection.'
    }
    Invoke-Element $button
    $searchBox = Wait-ById $Window 'SearchBox' 8000
    if (-not $searchBox) {
        throw 'The location picker did not open.'
    }
    return $searchBox
}

function Get-SelectButtons {
    param([System.Windows.Automation.AutomationElement]$Window)

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        $script:AE::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
    )
    $buttons = @()
    foreach ($button in $Window.FindAll($script:TS::Descendants, $condition)) {
        if ($button.Current.Name -like 'Select Location*') {
            $buttons += $button
        }
    }
    return $buttons
}

function Send-HoverTo {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [System.Windows.Automation.AutomationElement]$Element
    )

    $picker = Find-ById $Window 'LocationPickerWindow'
    if (-not $picker) {
        return
    }
    $handle = [IntPtr]$picker.Current.NativeWindowHandle
    if ($handle -eq [IntPtr]::Zero) {
        return
    }
    $windowRectangle = $picker.Current.BoundingRectangle
    $elementRectangle = $Element.Current.BoundingRectangle
    $x = [int]($elementRectangle.X - $windowRectangle.X +
        [Math]::Min(100, [int]($elementRectangle.Width / 2)))
    $y = [int]($elementRectangle.Y - $windowRectangle.Y +
        [int]($elementRectangle.Height / 2))
    $lParam = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
    [VpnCtlExpressWin32]::PostMessage(
        $handle,
        0x200,
        [IntPtr]::Zero,
        $lParam
    ) | Out-Null
    Start-Sleep -Milliseconds 500
}

function New-TimeoutError {
    param([string]$Message)

    if (Get-Command New-VpnCtlException -ErrorAction SilentlyContinue) {
        return New-VpnCtlException 'timeout' $Message 2
    }
    return New-Object -TypeName System.TimeoutException -ArgumentList $Message
}

function Get-VpnStatus {
    $window = Get-EvpnWindow
    [pscustomobject]@{
        state = ConvertTo-NormalizedState (Get-VpnStateText $window)
        location = Get-SelectedLocation $window
        tunnel = $(if (Test-TunnelUp) { 'up' } else { 'down' })
    }
}

function Connect-Vpn {
    param(
        [AllowEmptyString()]
        [string]$Location = '',
        [int]$TimeoutSec = 60
    )

    $window = Get-EvpnWindow
    $initialState = ConvertTo-NormalizedState (Get-VpnStateText $window)
    $initialLocation = Get-SelectedLocation $window
    if ($initialState -eq 'connected' -and
        ([string]::IsNullOrEmpty($Location) -or $initialLocation -ieq $Location)) {
        return [pscustomobject]@{
            state = 'connected'
            location = $initialLocation
            changed = $false
        }
    }

    if ([string]::IsNullOrEmpty($Location)) {
        $button = Find-ById $window 'VpnButton'
        if (-not $button) {
            throw 'VpnButton not found - the app UI may have changed.'
        }
        Invoke-Element $button
        if (-not (Wait-ForState $window '^Connected' $TimeoutSec)) {
            if (Test-SubscriptionRestriction $window) {
                throw (New-SubscriptionError)
            }
            $message = "ExpressVPN did not reach the connected state within $TimeoutSec seconds."
            throw (New-TimeoutError $message)
        }
        return [pscustomobject]@{
            state = 'connected'
            location = Get-SelectedLocation $window
            changed = $true
        }
    }

    $searchBox = $null
    try {
        $searchBox = Open-Picker $window
        $target = $null
        foreach ($button in Get-SelectButtons $window) {
            if ($button.Current.AutomationId -ieq $Location) {
                $target = $button
                break
            }
        }

        if (-not $target) {
            $valuePattern = $searchBox.GetCurrentPattern(
                [System.Windows.Automation.ValuePattern]::Pattern
            )
            $valuePattern.SetValue($Location)
            $deadline = (Get-Date).AddSeconds(8)
            $buttons = @()
            do {
                Start-Sleep -Milliseconds 500
                $buttons = @(Get-SelectButtons $window)
            } while ($buttons.Count -eq 0 -and (Get-Date) -lt $deadline)

            if ($buttons.Count -eq 0) {
                throw "No location matches '$Location'."
            }
            foreach ($button in $buttons) {
                if ($button.Current.AutomationId -ieq $Location) {
                    $target = $button
                    break
                }
            }
            if (-not $target) {
                if ($buttons.Count -eq 1) {
                    $target = $buttons[0]
                } else {
                    $names = ($buttons | ForEach-Object {
                        $_.Current.AutomationId
                    }) -join ', '
                    throw "Multiple locations match '$Location': $names"
                }
            }
        }

        $chosen = $target.Current.AutomationId
        Send-HoverTo $window $target
        foreach ($button in Get-SelectButtons $window) {
            if ($button.Current.AutomationId -ieq $chosen) {
                $target = $button
                break
            }
        }
        Invoke-Element $target

        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        do {
            $state = Get-VpnStateText $window
            $selected = Get-SelectedLocation $window
            if ($state -match '^Connected' -and $selected -ieq $chosen) {
                return [pscustomobject]@{
                    state = 'connected'
                    location = $chosen
                    changed = $true
                }
            }
            Start-Sleep -Milliseconds 800
        } while ((Get-Date) -lt $deadline)

        if (Test-SubscriptionRestriction $window) {
            throw (New-SubscriptionError)
        }
        $message = "ExpressVPN did not reach the connected state within $TimeoutSec seconds."
        throw (New-TimeoutError $message)
    } finally {
        Close-Picker $window
    }
}

function Disconnect-Vpn {
    param([int]$TimeoutSec = 30)

    $window = Get-EvpnWindow
    if ((ConvertTo-NormalizedState (Get-VpnStateText $window)) -eq 'disconnected') {
        return [pscustomobject]@{
            state = 'disconnected'
            changed = $false
        }
    }

    $button = Find-ById $window 'VpnButton'
    if (-not $button) {
        throw 'VpnButton not found - the app UI may have changed.'
    }
    Invoke-Element $button
    if (-not (Wait-ForState $window '^Not Connected' $TimeoutSec)) {
        $message = "ExpressVPN did not reach the disconnected state within $TimeoutSec seconds."
        throw (New-TimeoutError $message)
    }
    [pscustomobject]@{
        state = 'disconnected'
        changed = $true
    }
}

function Get-VpnLocations {
    $window = Get-EvpnWindow
    try {
        $searchBox = Open-Picker $window
        $valuePattern = $searchBox.GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern
        )
        if ($valuePattern.Current.Value) {
            $valuePattern.SetValue('')
            Start-Sleep -Milliseconds 800
        }

        $allTab = Find-ById $window 'AllTab'
        if ($allTab) {
            try {
                $allTab.GetCurrentPattern(
                    [System.Windows.Automation.SelectionItemPattern]::Pattern
                ).Select()
            } catch {
            }
            Start-Sleep -Milliseconds 1200
        }

        $treeItemCondition = New-Object System.Windows.Automation.PropertyCondition(
            $script:AE::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TreeItem
        )
        $treeCondition = New-Object System.Windows.Automation.PropertyCondition(
            $script:AE::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Tree
        )
        $locations = @()
        foreach ($tree in $window.FindAll($script:TS::Descendants, $treeCondition)) {
            foreach ($region in $tree.FindAll($script:TS::Children, $treeItemCondition)) {
                try {
                    $expand = $region.GetCurrentPattern(
                        [System.Windows.Automation.ExpandCollapsePattern]::Pattern
                    )
                    $expand.Expand()
                    Start-Sleep -Milliseconds 700
                    foreach ($item in $region.FindAll(
                        $script:TS::Descendants,
                        $treeItemCondition
                    )) {
                        $locations += [pscustomobject]@{
                            name = $item.Current.Name
                            region = $region.Current.Name
                        }
                    }
                    $expand.Collapse()
                    Start-Sleep -Milliseconds 300
                } catch {
                }
            }
        }
        return [pscustomobject]@{ locations = @($locations) }
    } finally {
        Close-Picker $window
    }
}

Export-ModuleMember -Function @(
    'Get-VpnStatus'
    'Connect-Vpn'
    'Disconnect-Vpn'
    'Get-VpnLocations'
)
