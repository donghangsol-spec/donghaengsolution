#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$ServiceName = "DonghaengCertificateBroker",
  [string]$InstallRoot = "$env:ProgramData\DonghaengSolution\CertificateBroker",
  [string]$NodePath = "C:\Program Files\nodejs\node.exe"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security
$sourceRoot = Split-Path -Parent $PSScriptRoot
$sourceCs = Join-Path $PSScriptRoot "CertificateBrokerService.cs"
$serviceExe = Join-Path $InstallRoot "$ServiceName.exe"
$secretPath = Join-Path $InstallRoot "control-token.dpapi"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw "Node.js executable not found: $NodePath" }
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw ".NET Framework C# compiler not found: $csc" }
if (-not (Test-Path -LiteralPath $sourceCs -PathType Leaf)) { throw "Reviewed service source not found: $sourceCs" }
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { throw "Service already exists: $ServiceName" }

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRoot "credential-session.mjs") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "server.mjs") -Destination $InstallRoot -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "package.json") -Destination $InstallRoot -Force
Copy-Item -LiteralPath $sourceCs -Destination $InstallRoot -Force

& $csc /nologo /target:exe /optimize+ /out:$serviceExe /reference:System.ServiceProcess.dll /reference:System.Security.dll $sourceCs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $serviceExe)) { throw "Local service compilation failed: $LASTEXITCODE" }
$serviceHash = (Get-FileHash -LiteralPath $serviceExe -Algorithm SHA256).Hash

$tokenBytes = New-Object byte[] 48
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
  $rng.GetBytes($tokenBytes)
  $protected = [Security.Cryptography.ProtectedData]::Protect($tokenBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
  [IO.File]::WriteAllBytes($secretPath, $protected)
  [Array]::Clear($protected, 0, $protected.Length)
} finally {
  $rng.Dispose()
  [Array]::Clear($tokenBytes, 0, $tokenBytes.Length)
}

$acl = Get-Acl -LiteralPath $InstallRoot
$acl.SetAccessRuleProtection($true, $false)
foreach ($identity in @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators", "NT AUTHORITY\LOCAL SERVICE")) {
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
    $identity, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
  )))
}
Set-Acl -LiteralPath $InstallRoot -AclObject $acl

$binaryPath = '"' + $serviceExe + '"'
& sc.exe create $ServiceName binPath= $binaryPath start= demand obj= "NT AUTHORITY\LocalService" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Service registration failed: $LASTEXITCODE" }
& sc.exe sidtype $ServiceName unrestricted | Out-Null
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/15000/""/0 | Out-Null

Write-Host "Installed $ServiceName in stopped/manual mode."
Write-Host "Locally compiled service SHA256: $serviceHash"
Write-Host "Run Test-ControlService.ps1 before starting the service."
