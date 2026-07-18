class VpnCtlException : System.Exception {
    [string]$Code
    [int]$ExitCode

    VpnCtlException([string]$code, [string]$message, [int]$exitCode) :
        base($message) {
        $this.Code = $code
        $this.ExitCode = $exitCode
    }
}

function New-VpnCtlException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )

    return [VpnCtlException]::new($Code, $Message, $ExitCode)
}

function Get-VpnCtlErrorInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    if ($Exception -is [VpnCtlException]) {
        return [pscustomobject][ordered]@{
            code = $Exception.Code
            message = $Exception.Message
            exitCode = $Exception.ExitCode
        }
    }

    return [pscustomobject][ordered]@{
        code = 'operational_error'
        message = $Exception.Message
        exitCode = 1
    }
}

function New-VpnCtlResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Ok,
        [AllowNull()][string]$Provider,
        [AllowNull()][string]$Command,
        [AllowNull()][object]$Data,
        [AllowNull()][string]$ErrorCode,
        [AllowNull()][string]$Message
    )

    $errorValue = $null
    if (-not $Ok) {
        $errorValue = [pscustomobject][ordered]@{
            code = $ErrorCode
            message = $Message
        }
    }

    return [pscustomobject][ordered]@{
        ok = $Ok
        provider = $Provider
        command = $Command
        data = $Data
        error = $errorValue
    }
}

Export-ModuleMember -Function New-VpnCtlResult, New-VpnCtlException, Get-VpnCtlErrorInfo
