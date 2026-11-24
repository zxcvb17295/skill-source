param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ScriptArguments
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'sync-mcp.py'

# Prefer WSL so one command updates Windows and the default WSL distribution.
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $linuxPath = & wsl.exe --exec wslpath -u $scriptPath 2>$null
        $wslExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    if ($wslExitCode -eq 0 -and $linuxPath) {
        & wsl.exe --exec python3 -B $linuxPath.Trim() @ScriptArguments
        exit $LASTEXITCODE
    }
}

# A Windows-only machine can still distribute its three client configurations.
if (Get-Command py.exe -ErrorAction SilentlyContinue) {
    & py.exe -3 -B $scriptPath @ScriptArguments
} elseif (Get-Command python.exe -ErrorAction SilentlyContinue) {
    & python.exe -B $scriptPath @ScriptArguments
} else {
    throw 'Python 3.11+ is required. Install Python or enable a WSL distribution with Python 3.11+.'
}
exit $LASTEXITCODE
