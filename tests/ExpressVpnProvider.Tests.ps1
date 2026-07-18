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

Remove-Module $module.Name -Force
Write-Output 'PASS: ExpressVPN provider static contract'
