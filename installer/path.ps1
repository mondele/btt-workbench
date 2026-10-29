# Adds a folder to, or removes it from, the user's or the system's PATH.
# Used by the BTT Workbench installer and uninstaller.
#
#   path.ps1 -Action Add|Remove -Dir <folder> -Scope User|Machine
#
# The PATH is read and written as stored (REG_EXPAND_SZ), so entries such
# as %SystemRoot% stay unexpanded; .NET's SetEnvironmentVariable would
# expand them.

param(
  [Parameter(Mandatory)][ValidateSet('Add', 'Remove')][string]$Action,
  [Parameter(Mandatory)][string]$Dir,
  [Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Scope
)

$ErrorActionPreference = 'Stop'
if ($Scope -eq 'Machine') {
  $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
} else {
  $key = 'HKCU:\Environment'
}

$raw = (Get-Item $key).GetValue('Path', '',
  [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$parts = @($raw -split ';' | Where-Object { $_ -ne '' })
$want = $Dir.TrimEnd('\')
$kept = @($parts | Where-Object { $_.TrimEnd('\') -ine $want })
if ($Action -eq 'Add') { $kept += $want }

$new = $kept -join ';'
if ($new -eq ($parts -join ';')) { exit 0 }
if ($new -eq '' -and $Scope -eq 'User') {
  Remove-ItemProperty -Path $key -Name Path -ErrorAction SilentlyContinue
} else {
  Set-ItemProperty -Path $key -Name Path -Value $new -Type ExpandString
}
