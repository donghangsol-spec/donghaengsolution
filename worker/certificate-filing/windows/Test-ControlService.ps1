[CmdletBinding()]
param(
  [string]$ServiceName = "DonghaengCertificateBroker",
  [string]$InstallRoot = "$env:ProgramData\DonghaengSolution\CertificateBroker"
)

$ErrorActionPreference = "Stop"
$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
if (-not $service) { throw "Service not installed: $ServiceName" }
if ($service.StartName -ne "NT AUTHORITY\LocalService") { throw "Unexpected service identity: $($service.StartName)" }
$serviceXml = Join-Path $InstallRoot "$ServiceName.xml"
if (-not (Test-Path -LiteralPath $serviceXml -PathType Leaf)) { throw "WinSW configuration is missing" }
$configText = Get-Content -LiteralPath $serviceXml -Raw
if ($configText -notmatch "-NonInteractive" -or $configText -notmatch "-ExecutionPolicy AllSigned") {
  throw "Hardened PowerShell flags are missing from WinSW configuration"
}
if ($service.PathName -notmatch [regex]::Escape("$ServiceName.exe")) { throw "Service is not hosted by the expected WinSW executable" }

$listener = Get-NetTCPConnection -LocalPort 47821 -State Listen -ErrorAction SilentlyContinue
if ($listener -and ($listener.LocalAddress | Where-Object { $_ -notin @("127.0.0.1", "::1") })) {
  throw "Worker is listening outside loopback"
}

$secretPath = Join-Path $InstallRoot "control-token.dpapi"
if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) { throw "Encrypted control token is missing" }
$aclText = (Get-Acl -LiteralPath $InstallRoot).Access.IdentityReference.Value
$unexpected = $aclText | Where-Object { $_ -notin @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators", "NT AUTHORITY\LOCAL SERVICE") }
if ($unexpected) { throw "Unexpected ACL principals: $($unexpected -join ', ')" }

[pscustomobject]@{
  ServiceIdentity = $service.StartName
  StartMode = $service.StartMode
  State = $service.State
  LoopbackOnly = $true
  EncryptedTokenPresent = $true
  AclPrincipals = $aclText -join "; "
}
