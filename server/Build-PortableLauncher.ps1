param([switch]$PackageOnly)
$ErrorActionPreference = 'Stop'
$header = @'
@echo off
setlocal DisableDelayedExpansion
set "NAS_BATCH_FILE=%~f0"
set "NAS_BATCH_MODE=%~1"
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "$ErrorActionPreference='Stop'; $nasBatchText=[IO.File]::ReadAllText($env:NAS_BATCH_FILE); $payload=[regex]::Match($nasBatchText,'(?ms)^:NAS_BOOT\r?\n(.*?)^:NAS_SERVER\r?$').Groups[1].Value; & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))))"
set "NAS_RESULT=%ERRORLEVEL%"
if /I not "%NAS_BATCH_MODE%"=="--check" if /I not "%NAS_BATCH_MODE%"=="--icon" if /I not "%NAS_BATCH_MODE%"=="--gui" pause
exit /b %NAS_RESULT%
'@

function Encode-File($name) {
    $inputPath = Join-Path $PSScriptRoot $name
    $text = ([IO.File]::ReadAllText($inputPath)).Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    [regex]::Matches($encoded, '.{1,100}') | ForEach-Object { $_.Value }
}

$package = Join-Path (Split-Path $PSScriptRoot -Parent) 'PrivateNAS.bat'
. (Join-Path $PSScriptRoot 'Write-WindowsIcon.ps1')
$iconSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'ios\PrivateNAS\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$iconFile = New-TemporaryFile
try {
    Write-WindowsIcon $iconSource $iconFile.FullName
    $icon = [Convert]::ToBase64String([IO.File]::ReadAllBytes($iconFile.FullName))
    $lines = @($header.TrimEnd() -split '\r?\n') + ':NAS_BOOT' +
        @(Encode-File 'PortableLauncher.ps1') + ':NAS_SERVER' + @(Encode-File 'nas.mjs') +
        ':NAS_ICON' + @([regex]::Matches($icon, '.{1,100}') | ForEach-Object { $_.Value })
    [IO.File]::WriteAllText($package, ($lines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
} finally { Remove-Item -LiteralPath $iconFile.FullName }
if ($PackageOnly) { return }
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$desktopFile = Join-Path $desktop '私人网盘.bat'
Copy-Item -LiteralPath $package -Destination $desktopFile -Force
& $desktopFile --icon
if ($LASTEXITCODE -ne 0) { throw 'Portable shortcut installation failed.' }
Write-Output $desktopFile
