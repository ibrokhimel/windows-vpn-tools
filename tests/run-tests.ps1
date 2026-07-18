$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$root = Split-Path -Parent $PSScriptRoot

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message`: expected [$Expected], got [$Actual]"
    }
}

function Assert-True {
    param($Actual, [string]$Message)
    if (-not $Actual) {
        throw "$Message`: expected a true value"
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        [Console]::Out.WriteLine("PASS $Name")
    } catch {
        $script:Failures.Add("$Name`: $($_.Exception.Message)")
        [Console]::Out.WriteLine("FAIL $Name")
    }
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-Cli {
    param([string[]]$Arguments)

    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $scriptPath = Join-Path $root 'vpnctl.ps1'
    $fakeProvider = Join-Path $PSScriptRoot 'fixtures\FakeProvider.psm1'
    $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $Arguments

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.Arguments = (($allArguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['VPNCTL_PROVIDER_MODULE'] = $fakeProvider

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd().TrimEnd("`r", "`n")
    $stderr = $process.StandardError.ReadToEnd().TrimEnd("`r", "`n")
    $process.WaitForExit()

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Assert-JsonBoundary {
    param($Result, [string]$Message)
    Assert-Equal 1 @($Result.Stdout -split "`r?`n" | Where-Object { $_ }).Count "$Message JSON line count"
    Assert-Equal '' $Result.Stderr "$Message stderr"
    try {
        return ($Result.Stdout | ConvertFrom-Json)
    } catch {
        throw "$Message invalid JSON: $($_.Exception.Message)"
    }
}

Test-Case 'common result success envelope' {
    Import-Module (Join-Path $root 'src\VpnCtl.Common.psm1') -Force
    $success = New-VpnCtlResult -Ok $true -Provider 'expressvpn' -Command 'status' `
        -Data ([pscustomobject]@{ state = 'connected' })
    Assert-True $success.ok 'success ok'
    Assert-Equal 'expressvpn' $success.provider 'success provider'
    Assert-Equal $null $success.error 'success error'
}

Test-Case 'common typed and fallback errors' {
    $exception = New-VpnCtlException -Code 'timeout' -Message 'too slow' -ExitCode 2
    $info = Get-VpnCtlErrorInfo -Exception $exception
    Assert-Equal 'timeout' $info.code 'typed error code'
    Assert-Equal 2 $info.exitCode 'typed error exit'
    $fallback = Get-VpnCtlErrorInfo -Exception ([Exception]::new('broken UI'))
    Assert-Equal 'operational_error' $fallback.code 'fallback code'
    Assert-Equal 1 $fallback.exitCode 'fallback exit'
}

Test-Case 'status normalizes provider and returns JSON' {
    $result = Invoke-Cli @('status', '--provider', 'EXPRESSVPN')
    Assert-Equal 0 $result.ExitCode 'status exit'
    $json = Assert-JsonBoundary $result 'status'
    Assert-True $json.ok 'status ok'
    Assert-Equal 'expressvpn' $json.provider 'normalized provider'
    Assert-Equal 'connected' $json.data.state 'normalized state'
}

Test-Case 'connect forwards location and timeout' {
    $result = Invoke-Cli @('connect', '--provider', 'hotspot-shield', '--location', 'New York', '--timeout', '12')
    Assert-Equal 0 $result.ExitCode 'connect exit'
    $json = Assert-JsonBoundary $result 'connect'
    Assert-Equal 'New York' $json.data.location 'location forwarded'
    Assert-Equal 12 $json.data.timeoutSec 'timeout forwarded'
}

Test-Case 'disconnect dispatches' {
    $result = Invoke-Cli @('disconnect', '--provider', 'expressvpn')
    $json = Assert-JsonBoundary $result 'disconnect'
    Assert-Equal 'disconnected' $json.data.state 'disconnect state'
}

Test-Case 'locations dispatches' {
    $result = Invoke-Cli @('locations', '--provider', 'expressvpn')
    $json = Assert-JsonBoundary $result 'locations'
    Assert-Equal 2 $json.data.locations.Count 'locations count'
}

@(
    @{ Name = 'invalid provider'; Args = @('status', '--provider', 'unknown') }
    @{ Name = 'invalid option combination'; Args = @('status', '--provider', 'expressvpn', '--location', 'Paris') }
    @{ Name = 'invalid timeout'; Args = @('connect', '--provider', 'expressvpn', '--timeout', '0') }
    @{ Name = 'unknown option'; Args = @('status', '--provider', 'expressvpn', '--bogus') }
    @{ Name = 'duplicate option'; Args = @('status', '--provider', 'expressvpn', '--provider', 'expressvpn') }
    @{ Name = 'missing option value'; Args = @('status', '--provider') }
) | ForEach-Object {
    $case = $_
    Test-Case $case.Name {
        $result = Invoke-Cli $case.Args
        Assert-Equal 64 $result.ExitCode "$($case.Name) exit"
        $json = Assert-JsonBoundary $result $case.Name
        Assert-Equal 'usage_error' $json.error.code "$($case.Name) code"
    }
}

Test-Case 'help is successful text' {
    $result = Invoke-Cli @('--help')
    Assert-Equal 0 $result.ExitCode 'help exit'
    Assert-True ($result.Stdout -match 'vpnctl\.ps1') 'help text'
    Assert-Equal '' $result.Stderr 'help stderr'
}

Test-Case 'text renders status fields' {
    $result = Invoke-Cli @('status', '--provider', 'expressvpn', '--text')
    Assert-Equal 0 $result.ExitCode 'text exit'
    Assert-True ($result.Stdout -match 'expressvpn') 'text provider'
    Assert-True ($result.Stdout -match 'status') 'text command'
    Assert-True ($result.Stdout -match 'connected') 'text state'
    Assert-True ($result.Stdout -match 'Test Location') 'text location'
    Assert-Equal '' $result.Stderr 'text stderr'
}

Test-Case 'typed provider timeout maps to exit 2' {
    $result = Invoke-Cli @('connect', '--provider', 'expressvpn', '--location', '__timeout__')
    Assert-Equal 2 $result.ExitCode 'timeout exit'
    $json = Assert-JsonBoundary $result 'timeout'
    Assert-Equal 'timeout' $json.error.code 'timeout code'
}

[Console]::Out.WriteLine("$script:Passed passed, $($script:Failures.Count) failed")
foreach ($failure in $script:Failures) {
    [Console]::Out.WriteLine("  $failure")
}
if ($script:Failures.Count -gt 0) { exit 1 }
