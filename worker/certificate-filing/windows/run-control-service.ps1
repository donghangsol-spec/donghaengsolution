[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$InstallRoot,
  [Parameter(Mandatory)] [string]$NodePath
)

$ErrorActionPreference = "Stop"
$secretPath = Join-Path $InstallRoot "control-token.dpapi"
$serverPath = Join-Path $InstallRoot "server.mjs"
$protected = [IO.File]::ReadAllBytes($secretPath)
$tokenBytes = $null
try {
  $tokenBytes = [Security.Cryptography.ProtectedData]::Unprotect(
    $protected,
    $null,
    [Security.Cryptography.DataProtectionScope]::LocalMachine
  )
  $env:WORKER_CONTROL_TOKEN = [Convert]::ToBase64String($tokenBytes)
  $env:WORKER_HOST = "127.0.0.1"
  $env:WORKER_PORT = "47821"
  & $NodePath $serverPath
  exit $LASTEXITCODE
} finally {
  Remove-Item Env:\WORKER_CONTROL_TOKEN -ErrorAction SilentlyContinue
  if ($tokenBytes) { [Array]::Clear($tokenBytes, 0, $tokenBytes.Length) }
  [Array]::Clear($protected, 0, $protected.Length)
}
