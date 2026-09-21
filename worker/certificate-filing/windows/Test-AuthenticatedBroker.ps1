#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$InstallRoot = "$env:ProgramData\DonghaengSolution\CertificateBroker",
  [string]$BrokerUrl = "http://127.0.0.1:47821"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security

$secretPath = Join-Path $InstallRoot "control-token.dpapi"
if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
  throw "Encrypted control token is missing: $secretPath"
}

$encrypted = [IO.File]::ReadAllBytes($secretPath)
$tokenBytes = $null
$token = $null
try {
  $tokenBytes = [Security.Cryptography.ProtectedData]::Unprotect(
    $encrypted,
    $null,
    [Security.Cryptography.DataProtectionScope]::LocalMachine
  )
  $token = [Convert]::ToBase64String($tokenBytes)
  $headers = @{ Authorization = "Bearer $token" }
  $response = Invoke-RestMethod -Method Get -Uri "$BrokerUrl/v1/public-key" -Headers $headers

  if (-not $response.keyId) { throw "Broker response is missing keyId" }
  if ($response.algorithm -ne "RSA-OAEP-256+A256GCM") {
    throw "Unexpected broker algorithm: $($response.algorithm)"
  }
  if (-not $response.pem.StartsWith("-----BEGIN PUBLIC KEY-----")) {
    throw "Broker response does not contain a valid public key"
  }
  $expiresAt = [DateTimeOffset]::Parse($response.expiresAt)
  if ($expiresAt -le [DateTimeOffset]::UtcNow) {
    throw "Broker public key is already expired"
  }

  [pscustomobject]@{
    Status = "AUTHENTICATED_BROKER_READY"
    Endpoint = "$BrokerUrl/v1/public-key"
    Authenticated = $true
    KeyId = $response.keyId
    Algorithm = $response.algorithm
    ExpiresAt = $response.expiresAt
    ControlTokenDisplayed = $false
    CertificateMaterialUsed = $false
    LiveInstitutionSubmission = $false
  }
} finally {
  if ($null -ne $tokenBytes) {
    [Array]::Clear($tokenBytes, 0, $tokenBytes.Length)
  }
  [Array]::Clear($encrypted, 0, $encrypted.Length)
  $token = $null
}
