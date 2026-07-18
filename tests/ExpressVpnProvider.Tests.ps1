$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\ExpressVpnProvider.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "ExpressVPN provider module does not exist: $modulePath"
}

$module = Import-Module $modulePath -Force -PassThru
$expectedCommands = @(
    'Get-VpnStatus'
    'Connect-Vpn'
    'Disconnect-Vpn'
    'Get-VpnLocations'
)

$exportedCommands = @($module.ExportedCommands.Keys)
foreach ($command in $expectedCommands) {
    if ($exportedCommands -notcontains $command) {
        throw "Expected exported command '$command'."
    }
}

foreach ($command in $exportedCommands) {
    if ($command -like 'Show-*' -or
        $command -eq 'Get-EvpnWindow' -or
        $command -eq 'Connect-ToLocation') {
        throw "Private helper '$command' must not be exported."
    }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $modulePath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw "Provider module has PowerShell parse errors: $($parseErrors.Message -join '; ')"
}

$forbiddenCommands = @('Write-Host', 'Write-Warning', 'exit')
$commands = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true)
foreach ($commandAst in $commands) {
    $commandName = $commandAst.GetCommandName()
    if ($commandName -and $forbiddenCommands -contains $commandName) {
        throw "Provider module must not invoke '$commandName'."
    }
}

foreach ($prompt in @(
    'Upgrade to Premium'
    'Subscribe to unlock this location'
    'Available with Premium'
    'Premium location'
    'Unlock with Premium'
    'Upgrade your plan'
    'Subscribers only'
)) {
    $isRestriction = & $module { param($Text) Test-SubscriptionRestrictionText $Text } $prompt
    if (-not $isRestriction) {
        throw "Explicit subscription prompt was not recognized: $prompt"
    }
}
if (& $module { Test-SubscriptionRestrictionText 'Explore our Premium locations' }) {
    throw 'Generic Premium marketing text must not be treated as a restriction.'
}
foreach ($prompt in 'ExpressVPN requires a software upgrade', 'This app needs an upgrade') {
    if (& $module { param($Text) Test-SubscriptionRestrictionText $Text } $prompt) {
        throw "Software upgrade text must not be treated as a subscription restriction: $prompt"
    }
}

function global:New-VpnCtlException {
    param([string]$Code, [string]$Message, [int]$ExitCode)
    $exception = New-Object System.Exception($Message)
    $exception.Data['VpnCtlCode'] = $Code
    $exception.Data['VpnCtlExitCode'] = $ExitCode
    return $exception
}

& $module {
    function script:Get-EvpnWindow { return [pscustomobject]@{} }
    function script:Get-VpnStateText { param($Window) return 'Connected' }
    function script:Get-SelectedLocation { param($Window) return 'Germany' }
    function script:Test-TunnelUp { return $true }
    function script:Find-ById { param($Root, $Id) return [pscustomobject]@{} }
    function script:Invoke-Element { param($Element) }
}
$status = Get-VpnStatus
if ($status.state -ne 'connected' -or $status.tunnel -ne 'up') {
    throw 'Status must normalize connected state and tunnel shape.'
}
$noop = Connect-Vpn -Location 'Germany' -TimeoutSec 1
if ($noop.changed) { throw 'Already-connected connect must be a no-op.' }

& $module {
    function script:Get-VpnStateText { param($Window) return 'Not Connected' }
}
$noop = Disconnect-Vpn -TimeoutSec 1
if ($noop.changed) { throw 'Already-disconnected disconnect must be a no-op.' }

& $module {
    function script:Get-VpnStateText { param($Window) return 'Not Connected' }
    function script:Get-SelectedLocation { param($Window) return 'France' }
    function script:Wait-ForState { param($Window, $Pattern, $Seconds) return $true }
}
$connected = Connect-Vpn -TimeoutSec 1
if (-not $connected.changed -or $connected.state -ne 'connected') {
    throw 'Successful connect must return normalized state and changed=true.'
}

& $module {
    function script:Get-VpnStateText { param($Window) return 'Connected' }
    function script:Wait-ForState { param($Window, $Pattern, $Seconds) return $true }
}
$disconnected = Disconnect-Vpn -TimeoutSec 1
if (-not $disconnected.changed -or $disconnected.state -ne 'disconnected') {
    throw 'Successful disconnect must return normalized state and changed=true.'
}

& $module {
    $script:pickerClosed = $false
    function script:Get-VpnStateText { param($Window) return 'Not Connected' }
    function script:Open-Picker { param($Window) return [pscustomobject]@{} }
    function script:Get-SelectButtons { param($Window) return @() }
    function script:Close-Picker { param($Window) $script:pickerClosed = $true }
    function script:Start-Sleep { param($Milliseconds) }
}
try { Connect-Vpn -Location 'Missing' -TimeoutSec 1; throw 'Expected missing location.' } catch {}
if (-not (& $module { $script:pickerClosed })) { throw 'Failing location path must close the picker.' }

& $module {
    function script:Find-ById { param($Root, $Id) return [pscustomobject]@{} }
    function script:Invoke-Element { param($Element) }
    function script:Wait-ForState { param($Window, $Pattern, $Seconds) return $false }
    function script:Test-SubscriptionRestriction { param($Window) return $true }
}
try {
    Connect-Vpn -TimeoutSec 1
    throw 'Expected subscription restriction.'
} catch {
    $code = if ($_.Exception.PSObject.Properties['Code']) { $_.Exception.Code } else { $_.Exception.Data['VpnCtlCode'] }
    $exitCode = if ($_.Exception.PSObject.Properties['ExitCode']) { $_.Exception.ExitCode } else { $_.Exception.Data['VpnCtlExitCode'] }
    if ($code -ne 'subscription_required' -or $exitCode -ne 4) {
        throw "ExpressVPN subscription restriction must map to subscription_required/4; got '$($_.Exception.Message)' code '$code'."
    }
}

& $module {
    function script:Get-VpnStateText { param($Window) return 'Not Connected' }
    function script:Wait-ForState { param($Window, $Pattern, $Seconds) return $false }
    function script:Test-SubscriptionRestriction { param($Window) return $false }
}
try {
    Connect-Vpn -TimeoutSec 1
    throw 'Expected timeout.'
} catch {
    $code = if ($_.Exception.PSObject.Properties['Code']) { $_.Exception.Code } else { $_.Exception.Data['VpnCtlCode'] }
    $exitCode = if ($_.Exception.PSObject.Properties['ExitCode']) { $_.Exception.ExitCode } else { $_.Exception.Data['VpnCtlExitCode'] }
    if ($code -ne 'timeout' -or $exitCode -ne 2) {
        throw 'ExpressVPN timeout must retain timeout/2 categorization.'
    }
}

Remove-Module $module.Name -Force
Remove-Item Function:\New-VpnCtlException -ErrorAction SilentlyContinue
Write-Output 'PASS: ExpressVPN provider static contract'
