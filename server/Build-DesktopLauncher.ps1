$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$output = Join-Path $desktop '私人网盘.exe'
$iconFile = New-TemporaryFile
$iconSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'ios\PrivateNAS\Assets.xcassets\AppIcon.appiconset\AppIcon.png'

. (Join-Path $PSScriptRoot 'Write-WindowsIcon.ps1')

try {
    Write-WindowsIcon $iconSource $iconFile.FullName
    & (Join-Path $PSScriptRoot 'Build-PortableLauncher.ps1') -PackageOnly
    $package = Join-Path (Split-Path $PSScriptRoot -Parent) 'PrivateNAS.bat'
    & $compiler /nologo /target:winexe /codepage:65001 /r:System.Windows.Forms.dll /r:System.Drawing.dll `
        "/win32icon:$($iconFile.FullName)" `
        "/resource:$package,PrivateNAS.bat" "/out:$output" (Join-Path $PSScriptRoot 'DesktopLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Desktop launcher build failed.' }
    Write-Output $output
} finally {
    Remove-Item -LiteralPath $iconFile.FullName
}
