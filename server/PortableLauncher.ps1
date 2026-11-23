$ErrorActionPreference = 'Stop'
if ($env:NAS_BATCH_MODE -eq '--gui') { [Console]::OutputEncoding = [Text.Encoding]::UTF8 }
$config = Join-Path $env:LOCALAPPDATA 'PrivateNAS'
$app = Join-Path $config 'portable'
$source = Join-Path $app 'nas.mjs'
$root = if (Test-Path 'E:\') { 'E:\PrivateNAS' } else { Join-Path $env:USERPROFILE 'PrivateNAS-Files' }
$node = (Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$cachedNode = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
if (!$node -and (Test-Path -LiteralPath $cachedNode)) { $node = $cachedNode }

function PlainText($secret) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-NodeRuntime {
    if ($node) {
        $version = & $node --version
        if ($version -match '^v(\d+)\.' -and [int]$Matches[1] -ge 22) { return $node }
    }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
    if (![Environment]::Is64BitOperatingSystem) { throw 'A 64-bit version of Windows is required.' }
    $version = 'v24.22.3'
    $filename = "win-$arch/node.exe"
    $base = "https://nodejs.org/dist/$version"
    $runtime = Join-Path $app "$version-$arch-node.exe"
    if (Test-Path -LiteralPath $runtime) { return $runtime }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host '正在从 Node.js 官方站点下载运行时…'
    $sums = (Invoke-WebRequest "$base/SHASUMS256.txt" -UseBasicParsing).Content
    $escaped = [regex]::Escape($filename)
    $hash = [regex]::Match($sums, "(?m)^([a-f0-9]{64})\s+$escaped\s*$").Groups[1].Value
    if (!$hash) { throw 'Node.js checksum missing.' }
    $temp = New-TemporaryFile
    try {
        Invoke-WebRequest "$base/$filename" -UseBasicParsing -OutFile $temp.FullName
        if ((Get-FileHash -LiteralPath $temp.FullName -Algorithm SHA256).Hash -ne $hash) {
            throw 'Node.js checksum did not match.'
        }
        Move-Item -LiteralPath $temp.FullName -Destination $runtime -Force
    } finally {
        if (Test-Path -LiteralPath $temp.FullName) { Remove-Item -LiteralPath $temp.FullName }
    }
    return $runtime
}

function Set-Owner {
    if ($env:NAS_BATCH_MODE -eq '--gui') {
        [Console]::InputEncoding = [Text.Encoding]::UTF8
        $name = [Console]::ReadLine()
        $entered = [Console]::ReadLine()
        if ($name -cnotmatch '^[\p{L}\p{Nd}_-]{1,32}\z' -or !$entered -or $entered.Length -lt 8 -or $entered.Length -gt 12) {
            throw '请输入有效的用户名和 8–12 位密码。'
        }
        $password = ConvertTo-SecureString $entered -AsPlainText -Force
        $entered = $null
    } else {
    do { $name = (Read-Host '设置网盘用户名（1–32 个字母、数字、下划线或连字符）').Trim() }
    until ($name -cmatch '^[\p{L}\p{Nd}_-]{1,32}\z')
    do {
        $password = Read-Host '设置网盘密码（8–12 个字符）' -AsSecureString
        if ($password.Length -ge 8 -and $password.Length -le 12) { break }
        $password.Dispose()
        Write-Warning '请输入 8–12 个字符。'
    } while ($true)
    }
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo.FileName = $node
        $process.StartInfo.Arguments = '"{0}" owner "{1}"' -f $source, $name
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardInput = $true
        [void]$process.Start()
        $bytes = [Text.Encoding]::UTF8.GetBytes((PlainText $password))
        try { $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length) }
        finally { [Array]::Clear($bytes, 0, $bytes.Length); $process.StandardInput.Close() }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw '无法保存网盘账号。' }
    } finally { $password.Dispose(); $process.Dispose() }
}

function Set-Certificate {
    $cert = Join-Path $config 'server-cert.pem'
    $key = Join-Path $config 'server-key.pem'
    if ((Test-Path -LiteralPath $cert) -and (Test-Path -LiteralPath $key)) {
        $env:NAS_TLS_CERT = $cert
        $env:NAS_TLS_KEY = $key
        return [Convert]::FromBase64String(([IO.File]::ReadAllText($cert) -replace '-----[^-]+-----',''))
    }
    $pfx = Join-Path $config 'portable.pfx'
    $passwordFile = Join-Path $config 'portable-pfx-password.txt'
    if (!(Test-Path -LiteralPath $pfx) -or !(Test-Path -LiteralPath $passwordFile)) {
        $secret = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')) -AsPlainText -Force
        $identity = New-SelfSignedCertificate -DnsName 'PrivateNAS' -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyAlgorithm RSA -KeyLength 3072 -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(1)
        try {
            Export-PfxCertificate -Cert $identity -FilePath $pfx -Password $secret -CryptoAlgorithmOption AES256_SHA256 -Force | Out-Null
            $secret | ConvertFrom-SecureString | Set-Content -LiteralPath $passwordFile -Encoding ASCII
        } finally { $secret.Dispose() }
    }
    $secret = (Get-Content -LiteralPath $passwordFile -Raw).Trim() | ConvertTo-SecureString
    try {
        $env:NAS_TLS_PFX = $pfx
        $env:NAS_TLS_PFX_PASSWORD = PlainText $secret
        $identity = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $pfx, $env:NAS_TLS_PFX_PASSWORD, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        try {
            [IO.File]::WriteAllBytes((Join-Path $config 'portable.cer'), $identity.RawData)
            return $identity.RawData
        }
        finally { $identity.Dispose() }
    } finally { $secret.Dispose() }
}

function Install-DesktopShortcut {
    $encoded = [regex]::Match($nasBatchText, '(?ms)^:NAS_ICON\r?\n(.*)\z').Groups[1].Value
    if (!$encoded) { throw 'The embedded app icon is missing.' }
    $iconPath = Join-Path $app 'PrivateNAS.ico'
    [IO.File]::WriteAllBytes($iconPath, [Convert]::FromBase64String($encoded))
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    if (!$desktop) { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcutPath = Join-Path $desktop '私人网盘（便携版）.lnk'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    if ($shortcut.TargetPath -and $shortcut.TargetPath -ne $env:NAS_BATCH_FILE) {
        return
    }
    $shortcut.TargetPath = $env:NAS_BATCH_FILE
    $shortcut.WorkingDirectory = Split-Path $env:NAS_BATCH_FILE -Parent
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Save()
}

try {
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    if ($env:NAS_BATCH_MODE -eq '--icon') {
        Install-DesktopShortcut
        exit 0
    }
    if (!$env:NAS_BATCH_MODE) {
        try { Install-DesktopShortcut }
        catch { Write-Warning '无法创建桌面快捷方式，网盘仍可启动。' }
    }
    $payload = [regex]::Match($nasBatchText, '(?ms)^:NAS_SERVER\r?\n(.*?)^:NAS_ICON\r?$').Groups[1].Value
    if (!$payload) { throw 'The embedded NAS server is missing.' }
    [IO.File]::WriteAllBytes($source, [Convert]::FromBase64String($payload))
    $node = Get-NodeRuntime
    if ($env:NAS_BATCH_MODE -eq '--check') {
        & $node --check $source
        exit $LASTEXITCODE
    }
    $env:NAS_CONFIG = $config
    $env:NAS_ROOT = $root
    $env:NAS_PORT = '8787'
    if ($env:NAS_BATCH_MODE -eq '--firewall') {
        $rule = Get-NetFirewallRule -Name 'PrivateNAS-Portable' -ErrorAction SilentlyContinue
        if (!$rule) {
            New-NetFirewallRule -Name 'PrivateNAS-Portable' -DisplayName 'PrivateNAS Portable HTTPS' -Program $node `
                -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8787 -Profile Private -RemoteAddress LocalSubnet | Out-Null
        } else {
            $rule | Get-NetFirewallApplicationFilter | Set-NetFirewallApplicationFilter -Program $node | Out-Null
        }
        Write-Host '已为专用网络开放网盘端口。'
        exit 0
    }
    $accountFile = Join-Path $config 'account.json'
    $listener = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        Write-Host '8787 端口已在使用。若网盘已经运行，直接从手机连接即可。'
    }
    if (Test-Path -LiteralPath $accountFile) {
        $account = Get-Content -LiteralPath $accountFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "使用已设置的网盘账号：$($account.username)"
    } elseif ($listener) {
        exit 0
    } elseif ($env:NAS_BATCH_MODE -eq '--gui') {
        Set-Owner
    } else {
        Write-Host "当前 Windows 用户：$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        Write-Host "没有找到网盘账号：$accountFile"
        if ((Read-Host '只有在这台电脑首次配置时才需要新建账号。输入 Y 继续，或按回车退出') -ne 'Y') {
            exit 0
        }
        Set-Owner
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($sha.ComputeHash([byte[]](Set-Certificate))).Replace('-', '') }
    finally { $sha.Dispose() }
    Write-Host "网盘目录：$root"
    Write-Host "证书指纹：$fingerprint"
    Get-NetIPConfiguration | Where-Object IPv4DefaultGateway | ForEach-Object {
        foreach ($address in $_.IPv4Address) { Write-Host "连接地址：https://$($address.IPAddress):8787" }
    }
    if ($listener) { exit 0 }
    if ($env:NAS_BATCH_MODE -eq '--gui') {
        Start-Process -FilePath $node -ArgumentList ('"{0}"' -f $source) -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $config 'service.log') `
            -RedirectStandardError (Join-Path $config 'service-error.log')
        exit 0
    }
    Write-Host '保持此窗口打开。按 Ctrl+C 停止服务。'
    & $node $source
    exit $LASTEXITCODE
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
