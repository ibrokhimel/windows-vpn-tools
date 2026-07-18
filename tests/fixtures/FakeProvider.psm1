function Get-VpnStatus {
    [pscustomobject]@{
        state = 'connected'
        location = 'Test Location'
        tunnel = 'up'
    }
}

function Connect-Vpn {
    param(
        [AllowEmptyString()][string]$Location = '',
        [int]$TimeoutSec = 60
    )

    if ($Location -eq '__timeout__') {
        throw (New-VpnCtlException -Code 'timeout' -Message 'Fake provider timed out.' -ExitCode 2)
    }

    [pscustomobject]@{
        state = 'connected'
        location = $Location
        changed = $true
        timeoutSec = $TimeoutSec
    }
}

function Disconnect-Vpn {
    param([int]$TimeoutSec = 30)
    [pscustomobject]@{
        state = 'disconnected'
        changed = $true
    }
}

function Get-VpnLocations {
    [pscustomobject]@{
        locations = @(
            [pscustomobject]@{ name = 'Germany' }
            [pscustomobject]@{ name = 'New York'; code = 'USNYC' }
        )
    }
}

Export-ModuleMember -Function Get-VpnStatus, Connect-Vpn, Disconnect-Vpn, Get-VpnLocations
