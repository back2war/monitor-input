# Renders the app icon (monitor with a blue screen and "switch" arrows) into app.ico.
# All sizes are stored as 32-bit DIBs: csc /win32icon and System.Drawing.Icon reject PNG entries.
# Usage: powershell -ExecutionPolicy Bypass -File make-icon.ps1 [-Preview]
param([switch]$Preview)

Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
$sizes = 16, 20, 24, 32, 40, 48, 64, 256

function New-RoundedRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($r -le 0.5) { $p.AddRectangle((New-Object System.Drawing.RectangleF($x, $y, $w, $h))); return $p }
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Draw-Arrow($g, $pen, $brush, [single]$x1, [single]$x2, [single]$y, [single]$head) {
    # Horizontal shaft from x1 to x2 with a filled triangular head at x2.
    $dir = [Math]::Sign($x2 - $x1)
    $g.DrawLine($pen, $x1, $y, $x2 - $dir * $head * 0.6, $y)
    $pts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF($x2, $y)),
        (New-Object System.Drawing.PointF(($x2 - $dir * $head), ($y - $head * 0.75))),
        (New-Object System.Drawing.PointF(($x2 - $dir * $head), ($y + $head * 0.75))))
    $g.FillPolygon($brush, $pts)
}

function Render([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    $bezel = [System.Drawing.Color]::FromArgb(255, 71, 85, 105)     # slate, readable on light and dark taskbars
    $top = [System.Drawing.Color]::FromArgb(255, 56, 189, 248)      # sky
    $bottom = [System.Drawing.Color]::FromArgb(255, 37, 99, 235)    # blue

    # Body (bezel)
    $bx = $s * 0.03; $by = $s * 0.08; $bw = $s * 0.94; $bh = $s * 0.66
    $body = New-RoundedRect $bx $by $bw $bh ([Math]::Max(1, $s * 0.08))
    $g.FillPath((New-Object System.Drawing.SolidBrush($bezel)), $body)

    # Screen
    $inset = [Math]::Max(1.5, $s * 0.07)
    $sx = $bx + $inset; $sy = $by + $inset; $sw = $bw - 2 * $inset; $sh = $bh - 2 * $inset
    $screen = New-RoundedRect $sx $sy $sw $sh ([Math]::Max(0, $s * 0.035))
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF($sx, $sy)), (New-Object System.Drawing.PointF($sx, ($sy + $sh))), $top, $bottom)
    $g.FillPath($grad, $screen)

    # Stand: neck + base
    $neckW = $s * 0.16; $neckH = $s * 0.10
    $g.FillRectangle((New-Object System.Drawing.SolidBrush($bezel)), ($s - $neckW) / 2, ($by + $bh - 0.5), $neckW, $neckH + 0.5)
    $baseW = $s * 0.52; $baseH = [Math]::Max(1.5, $s * 0.08)
    $base = New-RoundedRect (($s - $baseW) / 2) ($by + $bh + $neckH) $baseW $baseH ([Math]::Max(0, $baseH / 2))
    $g.FillPath((New-Object System.Drawing.SolidBrush($bezel)), $base)

    # Switch arrows: right arrow on top, left arrow below
    $white = [System.Drawing.Color]::White
    $stroke = [Math]::Max(1.4, $s * 0.075)
    $pen = New-Object System.Drawing.Pen($white, $stroke)
    $brush = New-Object System.Drawing.SolidBrush($white)
    $head = [Math]::Max(2.6, $s * 0.15)
    $ax1 = $sx + $sw * 0.18; $ax2 = $sx + $sw * 0.82
    Draw-Arrow $g $pen $brush $ax1 $ax2 ($sy + $sh * 0.32) $head
    Draw-Arrow $g $pen $brush $ax2 $ax1 ($sy + $sh * 0.70) $head

    $g.Dispose()
    return $bmp
}

function Get-DibBytes($bmp) {
    # BITMAPINFOHEADER + bottom-up BGRA pixels + 1-bit AND mask (all zero: alpha does the work).
    $s = $bmp.Width
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([int]40); $w.Write([int]$s); $w.Write([int]($s * 2)); $w.Write([int16]1); $w.Write([int16]32)
    $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
    for ($y = $s - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $s; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A)
        }
    }
    $maskRow = [int]([Math]::Ceiling($s / 32.0) * 4)
    $w.Write((New-Object byte[] ($maskRow * $s)))
    $w.Flush()
    return , $ms.ToArray()   # leading comma: keep byte[] from being unrolled into object[]
}

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$images = @()
foreach ($s in $sizes) {
    $bmp = Render $s
    if ($Preview) { $bmp.Save((Join-Path $dir "preview-$s.png"), [System.Drawing.Imaging.ImageFormat]::Png) }
    $images += , @{ Size = $s; Bytes = (Get-DibBytes $bmp) }
    $bmp.Dispose()
}

# ICO container: ICONDIR + ICONDIRENTRY[] + image data
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
    $dim = if ($img.Size -ge 256) { 0 } else { $img.Size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$img.Bytes.Length); $w.Write([int]$offset)
    $offset += $img.Bytes.Length
}
foreach ($img in $images) { $w.Write([byte[]]$img.Bytes) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path (Split-Path -Parent $dir) 'app.ico'), $out.ToArray())
Write-Host "Wrote app.ico ($($images.Count) sizes)"
