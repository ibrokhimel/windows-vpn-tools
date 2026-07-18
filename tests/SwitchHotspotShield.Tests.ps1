$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) {
        throw "$Message Pattern '$Pattern' was not found in '$Actual'."
    }
}

function Assert-CaseSensitiveMatch {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -cnotmatch $Pattern) {
        throw "$Message Pattern '$Pattern' was not found in '$Actual'."
    }
}

$root = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $root 'Switch-HotspotShield.ps1'
$source = Get-Content -Raw $scriptPath

Assert-Match $source "(?m)^\[CmdletBinding\(DefaultParameterSetName = 'Status'\)\]" `
    'Default parameter set must remain Status.'
foreach ($contract in @(
    "ParameterSetName = 'Location'",
    "ParameterSetName = 'Connect'",
    "ParameterSetName = 'Disconnect'",
    "ParameterSetName = 'Status'",
    "ParameterSetName = 'List'",
    '[string]$Location',
    '[switch]$Connect',
    '[switch]$Disconnect',
    '[switch]$Status',
    '[switch]$ListLocations',
    '[int]$TimeoutSec = 45'
)) {
    if (-not $source.Contains($contract)) {
        throw "Legacy parameter contract is missing '$contract'."
    }
}
Assert-Match $source 'HotspotShieldProvider\.psm1' 'Wrapper must import the provider module.'
Assert-Match $source 'VpnCtl\.Common\.psm1' 'Wrapper must import the common module.'
if ($source -match 'Add-Type\s+-AssemblyName\s+UIAutomation') {
    throw 'Wrapper must not contain direct UI Automation setup.'
}

function Invoke-Wrapper {
    param([string[]]$Arguments)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") +
        ($Arguments | ForEach-Object {
            if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        })
    $startInfo.Arguments = $quoted -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['VPNCTL_PROVIDER_MODULE'] =
        (Join-Path $PSScriptRoot 'fixtures\FakeProvider.psm1')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd().TrimEnd("`r", "`n")
    $stderr = $process.StandardError.ReadToEnd().TrimEnd("`r", "`n")
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

$status = Invoke-Wrapper @('-Status')
Assert-Equal $status.ExitCode 0 'Status exit code.'
Assert-CaseSensitiveMatch $status.Stdout '(?m)^State\s+: Connected\r?$' `
    'Status must retain title-cased legacy state text.'
Assert-Match $status.Stdout '(?m)^Location\s+: Test Location\r?$' 'Status must retain Location label.'

$location = Invoke-Wrapper @('-Location', 'New York', '-TimeoutSec', '12')
Assert-Equal $location.ExitCode 0 'Location connect exit code.'
Assert-Match $location.Stdout 'Connected\. Selected location: New York' `
    'Location connect must retain completion text.'

$connect = Invoke-Wrapper @('-Connect', '-TimeoutSec', '13')
Assert-Equal $connect.ExitCode 0 'Current connect exit code.'
Assert-Match $connect.Stdout '(?m)^Connected\.\r?$' 'Current connect must retain completion text.'

$disconnect = Invoke-Wrapper @('-Disconnect', '-TimeoutSec', '14')
Assert-Equal $disconnect.ExitCode 0 'Disconnect exit code.'
Assert-Match $disconnect.Stdout '(?m)^Disconnected\.\r?$' 'Disconnect must retain completion text.'

$locations = Invoke-Wrapper @('-ListLocations')
Assert-Equal $locations.ExitCode 0 'Locations exit code.'
Assert-Match $locations.Stdout '(?m)^Germany\r?$' 'Locations must print display names.'
Assert-Match $locations.Stdout '(?m)^USNYC : New York\r?$' 'Locations must preserve code and name.'

$timeout = Invoke-Wrapper @('-Location', '__timeout__')
Assert-Equal $timeout.ExitCode 2 'Typed provider timeout exit code.'
Assert-Equal $timeout.Stdout '' 'Failures must not write success output.'
Assert-Match $timeout.Stderr 'Fake provider timed out\.' 'Failures must write categorized message.'

Write-Output 'PASS: Hotspot Shield legacy wrapper contract and dispatch'
