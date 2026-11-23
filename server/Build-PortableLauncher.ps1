$ErrorActionPreference = 'Stop'
$header = @'
@echo off
setlocal DisableDelayedExpansion
set "NAS_BATCH_FILE=%~f0"
set "NAS_BATCH_MODE=%~1"
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "$ErrorActionPreference='Stop'; $nasBatchText=[IO.File]::ReadAllText($env:NAS_BATCH_FILE); $payload=[regex]::Match($nasBatchText,'(?ms)^:NAS_BOOT\r?\n(.*?)^:NAS_SERVER\r?$').Groups[1].Value; & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))))"
set "NAS_RESULT=%ERRORLEVEL%"
if /I not "%NAS_BATCH_MODE%"=="--check" pause
exit /b %NAS_RESULT%
'@

function Encode-File($name) {
    $inputPath = Join-Path $PSScriptRoot $name
    $text = ([IO.File]::ReadAllText($inputPath)).Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    [regex]::Matches($encoded, '.{1,100}') | ForEach-Object { $_.Value }
}

$lines = @($header.TrimEnd() -split '\r?\n') + ':NAS_BOOT' +
    @(Encode-File 'PortableLauncher.ps1') + ':NAS_SERVER' + @(Encode-File 'nas.mjs')
$package = Join-Path (Split-Path $PSScriptRoot -Parent) 'PrivateNAS.bat'
[IO.File]::WriteAllText($package, ($lines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$desktopFile = Join-Path $desktop '私人网盘.bat'
Copy-Item -LiteralPath $package -Destination $desktopFile -Force
Write-Output $desktopFile
