[CmdletBinding()]
param(
  [string]$RunnerUserName = "DonghaengMacroRunner",
  [string]$InstallRoot = "$env:ProgramData\DonghaengSolution\MacroRunner"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "관리자 권한 PowerShell에서 실행해야 합니다."
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $scriptRoot
$installScript = Join-Path $scriptRoot "install-interactive-runner.ps1"
$testScript = Join-Path $scriptRoot "Test-InteractiveRunner.ps1"

foreach ($requiredScript in @($installScript, $testScript)) {
  if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
    throw "필수 스크립트가 없습니다: $requiredScript"
  }
}

$existingUser = Get-LocalUser -Name $RunnerUserName -ErrorAction SilentlyContinue
$accountCreated = $false
if ($null -eq $existingUser) {
  Write-Host "샌드박스 실행 전용 계정의 새 비밀번호를 입력하세요."
  $password = Read-Host -AsSecureString
  $newUserParams = @{
    Name = $RunnerUserName
    Password = $password
    AccountNeverExpires = $true
    PasswordNeverExpires = $false
    UserMayNotChangePassword = $false
    Description = "Donghaeng Solution sandbox macro runner (non-administrator)"
  }
  New-LocalUser @newUserParams | Out-Null
  $accountCreated = $true
} else {
  if (-not $existingUser.Enabled) {
    throw "기존 실행 계정이 비활성 상태입니다. 계정 상태를 직접 확인한 뒤 다시 실행하세요."
  }
  if ($existingUser.PasswordRequired -eq $false) {
    throw "기존 실행 계정에 비밀번호 요구 설정이 없습니다. 계정 정책을 직접 수정한 뒤 다시 실행하세요."
  }
}

$runnerAccount = "$env:COMPUTERNAME\$RunnerUserName"
$administratorsGroup = Get-LocalGroup -SID "S-1-5-32-544" -ErrorAction Stop
$adminMembers = @(Get-LocalGroupMember -Group $administratorsGroup -ErrorAction Stop | ForEach-Object { $_.Name })
if ($adminMembers -contains $runnerAccount) {
  throw "실행 계정이 Administrators 그룹에 속해 있습니다. 관리자 권한을 제거해야 합니다."
}

$installParams = @{
  RunnerAccount = $runnerAccount
  SourceRoot = $sourceRoot
  InstallRoot = $InstallRoot
}
$installResult = & $installScript @installParams

$testParams = @{
  RunnerAccount = $runnerAccount
  InstallRoot = $InstallRoot
}
$testResult = & $testScript @testParams

[pscustomobject]@{
  Status = "SANDBOX_RUNNER_READY"
  AccountCreated = $accountCreated
  RunnerAccount = $runnerAccount
  InstallRoot = $InstallRoot
  AccountEnabled = $testResult.AccountEnabled
  PasswordRequired = $testResult.PasswordRequired
  RunnerIsAdministrator = $testResult.RunnerIsAdministrator
  AclInheritanceDisabled = $testResult.AclInheritanceDisabled
  RunnerReadExecuteOnly = $testResult.RunnerReadExecuteOnly
  ForbiddenSecretFiles = $testResult.ForbiddenSecretFiles
  LiveInstitutionSubmission = $false
  SHA256 = $testResult.SHA256
}
