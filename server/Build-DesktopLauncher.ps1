param([string]$NodePath = (Get-Command node -CommandType Application -ErrorAction Stop).Source)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$output = Join-Path $desktop '私人网盘.exe'
$settings = New-TemporaryFile
$iconFile = New-TemporaryFile
$iconSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'ios\PrivateNAS\Assets.xcassets\AppIcon.appiconset\AppIcon.png'

. (Join-Path $PSScriptRoot 'Write-WindowsIcon.ps1')

try {
    Write-WindowsIcon $iconSource $iconFile.FullName
    $NodePath, (Join-Path $PSScriptRoot 'nas.mjs') | Set-Content -LiteralPath $settings.FullName -Encoding UTF8
    & $compiler /nologo /target:winexe /codepage:65001 /r:System.Windows.Forms.dll /r:System.Drawing.dll `
        "/win32icon:$($iconFile.FullName)" `
        "/resource:$($settings.FullName),paths.txt" "/out:$output" (Join-Path $PSScriptRoot 'DesktopLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Desktop launcher build failed.' }
    Write-Output $output
} finally {
    Remove-Item -LiteralPath $settings.FullName,$iconFile.FullName
}
