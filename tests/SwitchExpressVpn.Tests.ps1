$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param([string]$Actual, [string]$Expected, [string]$Message)
    if (-not $Actual.Contains($Expected)) {
        throw "$Message Expected '$Expected' in '$Actual'."
    }
}

$root = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $root 'Switch-ExpressVpn.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) 'Wrapper must parse without errors.'

$actualParameters = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
$expectedParameters = @(
    'Location'
    'Connect'
    'Disconnect'
    'Status'
    'ListLocations'
    'TimeoutSec'
)
Assert-True (
    (Compare-Object $expectedParameters $actualParameters).Count -eq 0
) 'Wrapper parameter names changed.'

$parameterSets = @()
foreach ($parameter in $ast.ParamBlock.Parameters) {
    foreach ($attribute in $parameter.Attributes) {
        if ($attribute.TypeName.Name -eq 'Parameter') {
            foreach ($argument in $attribute.NamedArguments) {
                if ($argument.ArgumentName -eq 'ParameterSetName') {
                    $parameterSets += $argument.Argument.SafeGetValue()
                }
            }
        }
    }
}
$expectedSets = @('Location', 'Connect', 'Disconnect', 'Status', 'List')
Assert-True (
    (Compare-Object $expectedSets ($parameterSets | Select-Object -Unique)).Count -eq 0
) 'Wrapper parameter-set names changed.'

$source = Get-Content -Raw $scriptPath
Assert-Contains $source 'ExpressVpnProvider.psm1' 'Wrapper must import the provider module.'
Assert-Contains $source 'VpnCtl.Common.psm1' 'Wrapper must import the common module.'
Assert-True ($source -notmatch 'function\s+Get-EvpnWindow') 'Wrapper still contains direct UI automation.'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'vpnctl-express-wrapper-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$fakeProvider = Join-Path $tempRoot 'FakeExpressVpnProvider.psm1'
$callLog = Join-Path $tempRoot 'calls.txt'
@'
function Add-TestCall([string]$Value) {
    Add-Content -LiteralPath $env:VPNCTL_TEST_CALL_LOG -Value $Value
}
function Get-VpnStatus {
    Add-TestCall 'status'
    $state = $env:VPNCTL_TEST_STATUS_STATE
    if (-not $state) { $state = 'connected' }
    [pscustomobject]@{ state = $state; location = 'Germany'; tunnel = 'up' }
}
function Connect-Vpn {
    param([AllowEmptyString()][string]$Location = '', [int]$TimeoutSec = 60)
    Add-TestCall "connect|$Location|$TimeoutSec"
    if ($env:VPNCTL_TEST_ERROR -eq 'timeout') {
        throw (New-VpnCtlException 'timeout' 'timed out from fake provider' 2)
    }
    [pscustomobject]@{
        state = 'connected'
        location = $(if ($Location) { $Location } else { 'Smart Location' })
        changed = $true
    }
}
function Disconnect-Vpn {
    param([int]$TimeoutSec = 30)
    Add-TestCall "disconnect|$TimeoutSec"
    [pscustomobject]@{ state = 'disconnected'; changed = $true }
}
function Get-VpnLocations {
    Add-TestCall 'locations'
    [pscustomobject]@{
        locations = @(
            [pscustomobject]@{ name = 'Germany'; region = 'Europe' }
            [pscustomobject]@{ name = 'Japan'; region = 'Asia' }
        )
    }
}
Export-ModuleMember -Function Get-VpnStatus, Connect-Vpn, Disconnect-Vpn, Get-VpnLocations
'@ | Set-Content -LiteralPath $fakeProvider

$oldProvider = $env:VPNCTL_EXPRESSVPN_PROVIDER_MODULE
$oldLog = $env:VPNCTL_TEST_CALL_LOG
$oldError = $env:VPNCTL_TEST_ERROR
$oldStatusState = $env:VPNCTL_TEST_STATUS_STATE
try {
    $env:VPNCTL_EXPRESSVPN_PROVIDER_MODULE = $fakeProvider
    $env:VPNCTL_TEST_CALL_LOG = $callLog
    $env:VPNCTL_TEST_ERROR = ''
    $env:VPNCTL_TEST_STATUS_STATE = 'connected'

    $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Status 2>&1) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0) 'Status parameter set must succeed.'
    Assert-Contains $output 'State    : Connected' 'Connected must retain its legacy display text.'
    Assert-Contains $output 'Location : Germany' 'Status output lost the location label.'
    Assert-Contains $output 'Tunnel   : up' 'Status output lost the tunnel label.'

    foreach ($mapping in @(
        @{ normalized = 'disconnected'; display = 'Not Connected' }
        @{ normalized = 'connecting'; display = 'Connecting' }
        @{ normalized = 'unknown'; display = 'Unknown' }
    )) {
        $env:VPNCTL_TEST_STATUS_STATE = $mapping.normalized
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Status 2>&1) -join "`n"
        Assert-True ($LASTEXITCODE -eq 0) "Status mapping for '$($mapping.normalized)' must succeed."
        Assert-Contains $output ("State    : {0}" -f $mapping.display) (
            "Normalized state '$($mapping.normalized)' lost its legacy display text."
        )
    }

    $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Location 'USA - Miami' -TimeoutSec 17 2>&1) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0) 'Location parameter set must succeed.'
    Assert-Contains $output 'Connected to USA - Miami.' 'Location success text changed.'

    $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Connect -TimeoutSec 19 2>&1) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0) 'Connect parameter set must succeed.'
    Assert-Contains $output 'Connected.' 'Connect success text changed.'

    $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Disconnect -TimeoutSec 23 2>&1) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0) 'Disconnect parameter set must succeed.'
    Assert-Contains $output 'Disconnected.' 'Disconnect success text changed.'

    $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ListLocations 2>&1) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0) 'List parameter set must succeed.'
    Assert-Contains $output 'Germany' 'Location listing omitted Germany.'
    Assert-Contains $output 'Japan' 'Location listing omitted Japan.'

    $calls = @(Get-Content -LiteralPath $callLog)
    $expectedCalls = @(
        'status'
        'status'
        'status'
        'status'
        'connect|USA - Miami|17'
        'connect||19'
        'disconnect|23'
        'locations'
    )
    Assert-True (
        (Compare-Object $expectedCalls $calls).Count -eq 0
    ) 'A parameter set did not dispatch the expected provider arguments.'

    $env:VPNCTL_TEST_ERROR = 'timeout'
    $ErrorActionPreference = 'Continue'
    $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Connect 2>&1) -join "`n"
    $ErrorActionPreference = 'Stop'
    Assert-True ($LASTEXITCODE -eq 2) 'Categorized timeout must retain exit code 2.'
    Assert-Contains $output 'timed out from fake provider' 'Categorized error message was lost.'
} finally {
    $env:VPNCTL_EXPRESSVPN_PROVIDER_MODULE = $oldProvider
    $env:VPNCTL_TEST_CALL_LOG = $oldLog
    $env:VPNCTL_TEST_ERROR = $oldError
    $env:VPNCTL_TEST_STATUS_STATE = $oldStatusState
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

Write-Output 'PASS: ExpressVPN compatibility wrapper contract and dispatch'
