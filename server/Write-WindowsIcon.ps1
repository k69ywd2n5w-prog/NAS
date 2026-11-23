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
