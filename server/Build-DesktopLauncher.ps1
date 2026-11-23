param([string]$NodePath = (Get-Command node -CommandType Application -ErrorAction Stop).Source)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$output = Join-Path $desktop '私人网盘.exe'
$settings = New-TemporaryFile
$iconFile = New-TemporaryFile
$iconSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'ios\PrivateNAS\Assets.xcassets\AppIcon.appiconset\AppIcon.png'

function Write-WindowsIcon($source, $destination) {
    Add-Type -AssemblyName System.Drawing
    $original = [Drawing.Image]::FromFile($source)
    $images = @()
    try {
        foreach ($size in @(16, 32, 48, 256)) {
            $bitmap = [Drawing.Bitmap]::new($size, $size)
            $stream = [IO.MemoryStream]::new()
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.DrawImage($original, 0, 0, $size, $size)
                } finally { $graphics.Dispose() }
                $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
                $images += @{ Size = $size; Data = $stream.ToArray() }
            } finally { $stream.Dispose(); $bitmap.Dispose() }
        }
    } finally { $original.Dispose() }

    $writer = [IO.BinaryWriter]::new([IO.File]::Create($destination))
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$images.Count)
        $offset = 6 + 16 * $images.Count
        foreach ($item in $images) {
            $dimension = [byte]($item.Size % 256)
            $writer.Write($dimension)
            $writer.Write($dimension)
            $writer.Write([uint16]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$item.Data.Length)
            $writer.Write([uint32]$offset)
            $offset += $item.Data.Length
        }
        foreach ($item in $images) { $writer.Write([byte[]]$item.Data) }
    } finally { $writer.Dispose() }
}

try {
    Write-WindowsIcon $iconSource $iconFile.FullName
    $NodePath, (Join-Path $PSScriptRoot 'nas.mjs') | Set-Content -LiteralPath $settings.FullName -Encoding UTF8
    & $compiler /nologo /target:winexe /codepage:65001 /r:System.Windows.Forms.dll /r:System.Drawing.dll `
        "/win32icon:$($iconFile.FullName)" `
        "/resource:$($settings.FullName),paths.txt" "/out:$output" (Join-Path $PSScriptRoot 'DesktopLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Desktop launcher build failed.' }
    $bat = Join-Path $desktop '私人网盘.bat'
    if (Test-Path -LiteralPath $bat) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Join-Path $desktop '私人网盘（便携版）.lnk'))
        $shortcut.TargetPath = $bat
        $shortcut.WorkingDirectory = $desktop
        $shortcut.IconLocation = "$output,0"
        $shortcut.Save()
    }
    Write-Output $output
} finally {
    Remove-Item -LiteralPath $settings.FullName,$iconFile.FullName
}
