$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\HotspotShieldProvider.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Hotspot Shield provider module does not exist: $modulePath"
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

function global:New-VpnCtlException {
    param([string]$Code, [string]$Message, [int]$ExitCode)
    $exception = New-Object System.Exception($Message)
    $exception.Data['VpnCtlCode'] = $Code
    $exception.Data['VpnCtlExitCode'] = $ExitCode
    return $exception
}

$module = Import-Module $modulePath -Force -PassThru
$realWaitConnectResult = & $module { ${function:Wait-ConnectResult} }
$expectedCommands = @('Get-VpnStatus', 'Connect-Vpn', 'Disconnect-Vpn', 'Get-VpnLocations')
foreach ($command in $expectedCommands) {
    if ($module.ExportedCommands.Keys -notcontains $command) {
        throw "Expected exported command '$command'."
    }
}

& $module {
    function script:Get-HssWindow { return [pscustomobject]@{} }
    function script:Enter-Dashboard { param($Win) }
    function script:Get-SelectedLocation { param($Win) return 'Germany' }
    function script:Test-VpnConnected { return $true }
}
$status = Get-VpnStatus
Assert-Equal $status.state 'connected' 'Status must normalize state.'
Assert-Equal $status.location 'Germany' 'Status must return the selected location.'

& $module {
    function script:Test-VpnConnected { return $true }
}
$connected = Connect-Vpn -TimeoutSec 1
Assert-Equal $connected.changed $false 'Already-connected connect must be a no-op.'
Assert-Equal $connected.state 'connected' 'Connect must return final state.'

& $module {
    $script:selectedLocationQuery = $null
    function script:Test-VpnConnected { return $true }
    function script:Get-SelectedLocation { param($Win) return 'Germany' }
    function script:Select-HssLocation {
        param($Win, $Query)
        $script:selectedLocationQuery = $Query
    }
    function script:Wait-ConnectResult { param($Win, $Seconds) return 'connected' }
}
$switched = Connect-Vpn -Location 'France' -TimeoutSec 1
Assert-Equal $switched.changed $true 'A different requested location must trigger a switch.'
$selectedLocationQuery = & $module { $script:selectedLocationQuery }
Assert-Equal $selectedLocationQuery 'France' 'Connect must select the requested location.'

& $module { param($Implementation) Set-Item Function:\Wait-ConnectResult $Implementation } $realWaitConnectResult
& $module {
    $script:locationReads = 0
    function script:Test-VpnConnected { return $true }
    function script:Get-SelectedLocation {
        param($Win)
        $script:locationReads++
        if ($script:locationReads -lt 3) { return 'Germany' }
        return 'France'
    }
    function script:Select-HssLocation { param($Win, $Query) return 'FRPAR : France' }
    function script:Test-TextVisible { param($Win, $Pattern) return $false }
    function script:Start-Sleep { param($Milliseconds) }
}
$switched = Connect-Vpn -Location 'FRPAR' -TimeoutSec 1
Assert-Equal $switched.location 'France' 'Switch must wait for the requested display name or code.'
$locationReads = & $module { $script:locationReads }
if ($locationReads -lt 3) { throw 'Switch returned while the old connected tunnel was still selected.' }

& $module {
    function script:Test-VpnConnected { return $false }
    function script:Find-ById { param($Root, $Id) return [pscustomobject]@{} }
    function script:Invoke-El { param($El) }
    function script:Wait-ConnectResult { param($Win, $Seconds) return 'cant-connect' }
}
try {
    Connect-Vpn -TimeoutSec 1
    throw 'Expected provider failure.'
} catch {
    Assert-Equal $_.Exception.Data['VpnCtlCode'] 'provider_failure' 'Connect failure must be categorized.'
    Assert-Equal $_.Exception.Data['VpnCtlExitCode'] 3 'Provider failure must use exit code 3.'
}

& $module { param($Implementation) Set-Item Function:\Wait-ConnectResult $Implementation } $realWaitConnectResult
& $module {
    function script:Test-VpnConnected { return $false }
    function script:Test-TextVisible {
        param($Win, $Pattern)
        return $Pattern -match 'subscription'
    }
}
try {
    Connect-Vpn -TimeoutSec 1
    throw 'Expected subscription restriction.'
} catch {
    Assert-Equal $_.Exception.Data['VpnCtlCode'] 'subscription_required' 'Subscription restriction must be categorized.'
    Assert-Equal $_.Exception.Data['VpnCtlExitCode'] 4 'Subscription restriction must use exit code 4.'
}

& $module {
    function script:Wait-ConnectResult { param($Win, $Seconds) return 'timeout' }
}
try {
    Connect-Vpn -TimeoutSec 7
    throw 'Expected timeout.'
} catch {
    Assert-Equal $_.Exception.Data['VpnCtlCode'] 'timeout' 'Connect timeout must be categorized.'
    Assert-Equal $_.Exception.Data['VpnCtlExitCode'] 2 'Timeout must use exit code 2.'
}

& $module {
    function script:Open-LocationPicker { param($Win) return [pscustomobject]@{} }
    function script:Clear-LocationSearch { param($SearchBox) }
    function script:Get-LocationItemNames {
        param($Win)
        return @('USNYC : New York', 'Germany')
    }
}
$locations = @(Get-VpnLocations).locations
Assert-Equal $locations.Count 2 'Locations must return every realized item.'
Assert-Equal $locations[0].code 'USNYC' 'Locations must preserve provider code.'
Assert-Equal $locations[0].name 'New York' 'Locations must separate display name.'
Assert-Equal $locations[1].name 'Germany' 'Locations without codes must preserve name.'

Remove-Module $module.Name -Force
Remove-Item Function:\New-VpnCtlException -ErrorAction SilentlyContinue
Write-Output 'PASS: Hotspot Shield provider contract and behavior'
