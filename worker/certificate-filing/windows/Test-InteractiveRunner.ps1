[CmdletBinding()]
param(
  [string]$RunnerAccount = "$env:COMPUTERNAME\DonghaengMacroRunner",
  [string]$InstallRoot = "$env:ProgramData\DonghaengSolution\MacroRunner"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
  throw "Runner directory is missing: $InstallRoot"
}

$localName = ($RunnerAccount -split "\\")[-1]
$user = Get-LocalUser -Name $localName -ErrorAction Stop
if (-not $user.Enabled) { throw "Runner account is disabled" }
if ($user.PasswordRequired -eq $false) { throw "Runner account must require a password" }

$administratorsGroup = Get-LocalGroup -SID "S-1-5-32-544" -ErrorAction Stop
$adminMembers = @(Get-LocalGroupMember -Group $administratorsGroup -ErrorAction Stop | ForEach-Object { $_.Name })
if ($adminMembers -contains $RunnerAccount) { throw "Runner account is an administrator" }

$acl = Get-Acl -LiteralPath $InstallRoot
if (-not $acl.AreAccessRulesProtected) { throw "Runner ACL inheritance must be disabled" }
$expected = @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators", $RunnerAccount)
$rules = @($acl.Access)
$unexpected = @($rules | Where-Object { $_.IdentityReference.Value -notin $expected })
if ($unexpected.Count -gt 0) {
  throw "Unexpected runner ACL principals: $($unexpected.IdentityReference.Value -join ', ')"
}
foreach ($principal in $expected) {
  if ($principal -notin @($rules.IdentityReference.Value)) {
    throw "Required runner ACL principal is missing: $principal"
  }
}

$runnerRules = @($rules | Where-Object { $_.IdentityReference.Value -eq $RunnerAccount })
$dangerousRights =
  [Security.AccessControl.FileSystemRights]::WriteData -bor
  [Security.AccessControl.FileSystemRights]::AppendData -bor
  [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
  [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
  [Security.AccessControl.FileSystemRights]::Delete -bor
  [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
  [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
  [Security.AccessControl.FileSystemRights]::TakeOwnership
if ($runnerRules | Where-Object {
  $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
  ($_.FileSystemRights -band $dangerousRights) -ne 0
}) {
  throw "Runner account has write or administrative file rights"
}

$forbidden = @(
  Get-ChildItem -LiteralPath $InstallRoot -Recurse -Force -File |
    Where-Object {
      $_.Name -match "(?i)(\.env|\.pfx|\.p12|\.key|\.pem)$" -or
      $_.Name -match "(?i)(password|credential|secret|token)"
    }
)
if ($forbidden.Count -gt 0) {
  throw "Forbidden secret or certificate files found: $($forbidden.FullName -join ', ')"
}

$requiredFiles = @("interactive-runner.mjs", "macro-runner.mjs", "server-gate-client.mjs", "signed-receipt.mjs", "package.json")
$hashes = @{}
foreach ($file in $requiredFiles) {
  $path = Join-Path $InstallRoot $file
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required runner file missing: $file" }
  $hashes[$file] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

[pscustomobject]@{
  RunnerAccount = $RunnerAccount
  AccountEnabled = $user.Enabled
  PasswordRequired = $user.PasswordRequired
  RunnerIsAdministrator = $false
  AclInheritanceDisabled = $acl.AreAccessRulesProtected
  RunnerReadExecuteOnly = $true
  ForbiddenSecretFiles = 0
  SHA256 = ($hashes.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "; "
}
