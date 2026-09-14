[CmdletBinding()]
param(
  [string]$ServiceName = "DonghaengCertificateBroker",
  [string]$InstallRoot = "$env:ProgramData\DonghaengSolution\CertificateBroker"
)

$ErrorActionPreference = "Stop"
$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
if (-not $service) { throw "Service not installed: $ServiceName" }
if ($service.StartName -ne "NT AUTHORITY\LocalService") { throw "Unexpected service identity: $($service.StartName)" }

$serviceExe = Join-Path $InstallRoot "$ServiceName.exe"
$serviceSource = Join-Path $InstallRoot "CertificateBrokerService.cs"
$secretPath = Join-Path $InstallRoot "control-token.dpapi"
if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) { throw "Locally compiled service executable is missing" }
if (-not (Test-Path -LiteralPath $serviceSource -PathType Leaf)) { throw "Auditable service source is missing" }
if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) { throw "Encrypted control token is missing" }
if ($service.PathName -notmatch [regex]::Escape("$ServiceName.exe")) { throw "Service path does not use the expected local build" }

$listener = Get-NetTCPConnection -LocalPort 47821 -State Listen -ErrorAction SilentlyContinue
if ($listener -and ($listener.LocalAddress | Where-Object { $_ -notin @("127.0.0.1", "::1") })) {
  throw "Worker is listening outside loopback"
}

$aclText = (Get-Acl -LiteralPath $InstallRoot).Access.IdentityReference.Value
$unexpected = $aclText | Where-Object { $_ -notin @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators", "NT AUTHORITY\LOCAL SERVICE") }
if ($unexpected) { throw "Unexpected ACL principals: $($unexpected -join ', ')" }

[pscustomobject]@{
  ServiceIdentity = $service.StartName
  StartMode = $service.StartMode
  State = $service.State
  LoopbackOnly = $true
  EncryptedTokenPresent = $true
  ServiceSHA256 = (Get-FileHash -LiteralPath $serviceExe -Algorithm SHA256).Hash
  SourceSHA256 = (Get-FileHash -LiteralPath $serviceSource -Algorithm SHA256).Hash
  AclPrincipals = $aclText -join "; "
}
