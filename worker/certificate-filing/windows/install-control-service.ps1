#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$ServiceName = "DonghaengCertificateBroker",
  [string]$InstallRoot = "$env:ProgramData\DonghaengSolution\CertificateBroker",
  [string]$NodePath = "C:\Program Files\nodejs\node.exe",
  [Parameter(Mandatory)] [string]$WinSWPath
)

$ErrorActionPreference = "Stop"
$sourceRoot = Split-Path -Parent $PSScriptRoot
$runnerPath = Join-Path $InstallRoot "windows\run-control-service.ps1"
$secretPath = Join-Path $InstallRoot "control-token.dpapi"

if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
  throw "Node.js executable not found: $NodePath"
}
if (-not (Test-Path -LiteralPath $WinSWPath -PathType Leaf)) {
  throw "Approved WinSW executable not found: $WinSWPath"
}
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
  throw "Service already exists: $ServiceName"
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRoot "credential-session.mjs") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "server.mjs") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "package.json") -Destination $InstallRoot -Force
New-Item -ItemType Directory -Path (Join-Path $InstallRoot "windows") -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "run-control-service.ps1") -Destination $runnerPath -Force
$serviceExe = Join-Path $InstallRoot "$ServiceName.exe"
$serviceXml = Join-Path $InstallRoot "$ServiceName.xml"
Copy-Item -LiteralPath $WinSWPath -Destination $serviceExe -Force

$tokenBytes = New-Object byte[] 48
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
  $rng.GetBytes($tokenBytes)
  $protected = [Security.Cryptography.ProtectedData]::Protect(
    $tokenBytes,
    $null,
    [Security.Cryptography.DataProtectionScope]::LocalMachine
  )
  [IO.File]::WriteAllBytes($secretPath, $protected)
} finally {
  $rng.Dispose()
  [Array]::Clear($tokenBytes, 0, $tokenBytes.Length)
}

$powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$escapedPowerShell = [Security.SecurityElement]::Escape($powerShell)
$escapedRunner = [Security.SecurityElement]::Escape($runnerPath)
$escapedInstallRoot = [Security.SecurityElement]::Escape($InstallRoot)
$escapedNodePath = [Security.SecurityElement]::Escape($NodePath)
$config = @"
<service>
  <id>$ServiceName</id>
  <name>Donghaeng Certificate Control Broker</name>
  <description>Local-only credential session broker. It does not run browser automation.</description>
  <executable>$escapedPowerShell</executable>
  <arguments>-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File &quot;$escapedRunner&quot; -InstallRoot &quot;$escapedInstallRoot&quot; -NodePath &quot;$escapedNodePath&quot;</arguments>
  <startmode>Manual</startmode>
  <serviceaccount>
    <domain>NT AUTHORITY</domain>
    <user>LocalService</user>
    <allowservicelogon>true</allowservicelogon>
  </serviceaccount>
  <onfailure action="restart" delay="5 sec" />
  <onfailure action="restart" delay="15 sec" />
  <resetfailure>1 day</resetfailure>
  <logpath>$escapedInstallRoot\logs</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>4</keepFiles>
  </log>
</service>
"@
[IO.File]::WriteAllText($serviceXml, $config, [Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Join-Path $InstallRoot "logs") -Force | Out-Null

$acl = Get-Acl -LiteralPath $InstallRoot
$acl.SetAccessRuleProtection($true, $false)
foreach ($identity in @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators", "NT AUTHORITY\LOCAL SERVICE")) {
  $rule = New-Object Security.AccessControl.FileSystemAccessRule(
    $identity,
    "ReadAndExecute",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
  )
  $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $InstallRoot -AclObject $acl
$logAcl = Get-Acl -LiteralPath (Join-Path $InstallRoot "logs")
$logAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
  "NT AUTHORITY\LOCAL SERVICE",
  "Modify",
  "ContainerInherit,ObjectInherit",
  "None",
  "Allow"
)))
Set-Acl -LiteralPath (Join-Path $InstallRoot "logs") -AclObject $logAcl

& $serviceExe install
if ($LASTEXITCODE -ne 0) { throw "WinSW service install failed: $LASTEXITCODE" }
& sc.exe sidtype $ServiceName unrestricted | Out-Null

Write-Host "Installed $ServiceName in stopped/manual mode."
Write-Host "Sign the PowerShell scripts, verify the approved WinSW hash, run Test-ControlService.ps1, then start only after review."
