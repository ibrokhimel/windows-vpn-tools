param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$CliArgs
)

$ErrorActionPreference = 'Stop'
$commonModule = Join-Path $PSScriptRoot 'src\VpnCtl.Common.psm1'
Import-Module $commonModule -Force

function Write-VpnCtlJson {
    param($Value)
    [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 8 -Compress))
}

function Show-VpnCtlHelp {
    [Console]::Out.WriteLine(@'
Usage: vpnctl.ps1 <status|connect|disconnect|locations> --provider <expressvpn|hotspot-shield> [options]

Options:
  --location <name>   Location for connect only
  --timeout <seconds> Positive operation timeout
  --text              Human-readable output
  --help              Show this help
'@)
}

function Format-VpnCtlText {
    param($Result)

    $lines = @(
        "Provider: $($Result.provider)"
        "Command: $($Result.command)"
    )
    if ($null -ne $Result.data) {
        foreach ($property in $Result.data.PSObject.Properties) {
            if ($property.Name -eq 'locations') {
                $lines += 'Locations:'
                foreach ($location in @($property.Value)) {
                    $lines += "  $($location.name)"
                }
            } elseif ($property.Value -isnot [System.Collections.IEnumerable] -or
                $property.Value -is [string]) {
                $lines += "$($property.Name): $($property.Value)"
            }
        }
    }
    if ($null -ne $Result.error) {
        $lines += "Error: $($Result.error.code)"
        $lines += "Message: $($Result.error.message)"
    }
    return ($lines -join [Environment]::NewLine)
}

$command = $null
$provider = $null
$text = $false
$location = $null
$timeout = $null
$exitCode = 0

try {
    $arguments = @($CliArgs)
    if ($arguments.Count -eq 1 -and [string]$arguments[0] -eq '--help') {
        Show-VpnCtlHelp
        exit 0
    }
    if ($arguments.Count -eq 0) {
        throw (New-VpnCtlException -Code 'usage_error' -Message 'A command is required.' -ExitCode 64)
    }

    $command = ([string]$arguments[0]).ToLowerInvariant()
    if ($command -notin @('status', 'connect', 'disconnect', 'locations')) {
        throw (New-VpnCtlException -Code 'usage_error' -Message "Unknown command '$command'." -ExitCode 64)
    }

    $seen = @{}
    for ($index = 1; $index -lt $arguments.Count; $index++) {
        $option = ([string]$arguments[$index]).ToLowerInvariant()
        if ($option -notin @('--provider', '--location', '--timeout', '--text')) {
            throw (New-VpnCtlException -Code 'usage_error' -Message "Unknown option '$option'." -ExitCode 64)
        }
        if ($seen.ContainsKey($option)) {
            throw (New-VpnCtlException -Code 'usage_error' -Message "Option '$option' was specified more than once." -ExitCode 64)
        }
        $seen[$option] = $true

        if ($option -eq '--text') {
            $text = $true
            continue
        }
        if (($index + 1) -ge $arguments.Count -or ([string]$arguments[$index + 1]).StartsWith('--')) {
            throw (New-VpnCtlException -Code 'usage_error' -Message "Option '$option' requires a value." -ExitCode 64)
        }
        $index++
        $value = [string]$arguments[$index]
        switch ($option) {
            '--provider' { $provider = $value.ToLowerInvariant() }
            '--location' { $location = $value }
            '--timeout' {
                $parsedTimeout = 0
                if (-not [int]::TryParse($value, [ref]$parsedTimeout) -or $parsedTimeout -le 0) {
                    throw (New-VpnCtlException -Code 'usage_error' -Message 'Timeout must be a positive integer.' -ExitCode 64)
                }
                $timeout = $parsedTimeout
            }
        }
    }

    if ([string]::IsNullOrEmpty($provider)) {
        throw (New-VpnCtlException -Code 'usage_error' -Message 'The --provider option is required.' -ExitCode 64)
    }
    if ($provider -notin @('expressvpn', 'hotspot-shield')) {
        throw (New-VpnCtlException -Code 'usage_error' -Message "Unknown provider '$provider'." -ExitCode 64)
    }
    if ($null -ne $location -and $command -ne 'connect') {
        throw (New-VpnCtlException -Code 'usage_error' -Message '--location is valid only for connect.' -ExitCode 64)
    }

    $providerFiles = @{
        'expressvpn' = 'src\ExpressVpnProvider.psm1'
        'hotspot-shield' = 'src\HotspotShieldProvider.psm1'
    }
    $providerModule = $null
    if (-not [string]::IsNullOrEmpty($env:VPNCTL_PROVIDER_MODULE) -and
        (Test-Path -LiteralPath $env:VPNCTL_PROVIDER_MODULE -PathType Leaf) -and
        [IO.Path]::GetExtension($env:VPNCTL_PROVIDER_MODULE) -ieq '.psm1') {
        $providerModule = $env:VPNCTL_PROVIDER_MODULE
    } else {
        $providerModule = Join-Path $PSScriptRoot $providerFiles[$provider]
    }
    Import-Module $providerModule -Force

    switch ($command) {
        'status' { $data = Get-VpnStatus }
        'connect' {
            $parameters = @{}
            if ($null -ne $location) { $parameters.Location = $location }
            if ($null -ne $timeout) { $parameters.TimeoutSec = $timeout }
            $data = Connect-Vpn @parameters
        }
        'disconnect' {
            $parameters = @{}
            if ($null -ne $timeout) { $parameters.TimeoutSec = $timeout }
            $data = Disconnect-Vpn @parameters
        }
        'locations' { $data = Get-VpnLocations }
    }

    $result = New-VpnCtlResult -Ok $true -Provider $provider -Command $command -Data $data
    if ($text) {
        [Console]::Out.WriteLine((Format-VpnCtlText $result))
    } else {
        Write-VpnCtlJson $result
    }
} catch {
    $info = Get-VpnCtlErrorInfo -Exception $_.Exception
    $result = New-VpnCtlResult -Ok $false -Provider $provider -Command $command `
        -ErrorCode $info.code -Message $info.message
    if ($text) {
        [Console]::Out.WriteLine((Format-VpnCtlText $result))
    } else {
        Write-VpnCtlJson $result
    }
    $exitCode = $info.exitCode
}

exit $exitCode
