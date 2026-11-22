param([string]$Username, [string]$NodePath = (Get-Command node -CommandType Application).Source)
$ErrorActionPreference = 'Stop'
$usernameRule = '^[\p{L}\p{Nd}_-]{1,32}\z'
while ($Username -cnotmatch $usernameRule) {
    if ($Username) { Write-Warning '用户名须为 1–32 个字符，可用中文、字母、数字、下划线和连字符。' }
    $Username = (Read-Host '请输入网盘用户名').Trim()
}
if (!$NodePath) { throw 'Specify the path to node.exe with -NodePath.' }
while ($true) {
    $password = Read-Host '请输入网盘密码（8–12 个字符，输入时隐藏）' -AsSecureString
    if ($password.Length -ge 8 -and $password.Length -le 12) { break }
    $password.Dispose()
    Write-Warning '密码长度须为 8–12 个字符，请重新输入。'
}
$secret = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
try {
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $NodePath
    $process.StartInfo.ArgumentList.Add((Join-Path $PSScriptRoot 'nas.mjs'))
    $process.StartInfo.ArgumentList.Add('owner')
    $process.StartInfo.ArgumentList.Add($Username)
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    [void]$process.Start()
    $process.StandardInput.Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($secret))
    $process.StandardInput.Close()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw 'Could not save account' }
    Write-Host '网盘账号设置成功。' -ForegroundColor Green
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secret)
    $password.Dispose()
}
