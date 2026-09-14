[CmdletBinding()]
param(
  [string]$RunnerAccount = "$env:COMPUTERNAME\DonghaengMacroRunner",
  [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$InstallRoot = "$env:ProgramData\DonghaengSolution\MacroRunner"
)

$ErrorActionPreference = "Stop"

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Administrator elevation is required to install the runner files"
}

$account = New-Object Security.Principal.NTAccount($RunnerAccount)
try {
  $null = $account.Translate([Security.Principal.SecurityIdentifier])
} catch {
  throw "Runner account does not exist: $RunnerAccount"
}

$adminMembers = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop | ForEach-Object { $_.Name })
if ($adminMembers -contains $RunnerAccount) {
  throw "Runner account must not be an administrator"
}

$requiredFiles = @(
  "interactive-runner.mjs",
  "macro-runner.mjs",
  "server-gate-client.mjs",
  "signed-receipt.mjs",
  "package.json"
)
foreach ($file in $requiredFiles) {
  $source = Join-Path $SourceRoot $file
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "Required runner source is missing: $source"
  }
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse

foreach ($file in $requiredFiles) {
  Copy-Item -LiteralPath (Join-Path $SourceRoot $file) -Destination (Join-Path $InstallRoot $file) -Force
}

$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$inherit = [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
$propagation = [Security.AccessControl.PropagationFlags]::None
$allow = [Security.AccessControl.AccessControlType]::Allow
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", $inherit, $propagation, $allow)))
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", $inherit, $propagation, $allow)))
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($RunnerAccount, "ReadAndExecute", $inherit, $propagation, $allow)))
Set-Acl -LiteralPath $InstallRoot -AclObject $acl

$hashes = @{}
foreach ($file in $requiredFiles) {
  $hashes[$file] = (Get-FileHash -LiteralPath (Join-Path $InstallRoot $file) -Algorithm SHA256).Hash
}

[pscustomobject]@{
  RunnerAccount = $RunnerAccount
  InstallRoot = $InstallRoot
  RunnerIsAdministrator = $false
  RunnerWritePermissionGranted = $false
  Files = $requiredFiles -join "; "
  SHA256 = ($hashes.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "; "
}
