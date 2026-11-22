# Run as administrator on the Windows NAS machine.
param([string]$NodePath = (Get-Command node -CommandType Application).Source)
$ErrorActionPreference = 'Stop'
$rule = Get-NetFirewallRule -Name 'PrivateNAS-HTTPS' -ErrorAction SilentlyContinue
if (!$rule) {
    New-NetFirewallRule -Name 'PrivateNAS-HTTPS' -DisplayName 'PrivateNAS HTTPS' -Program $NodePath `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8787 -Profile Private | Out-Null
}
