Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

# Turn each legacy square launcher bitmap into a proper adaptive icon:
#   background layer = the badge fill colour, filling the whole 108dp canvas
#   foreground layer = the glyph ALONE on transparency, sized for the safe zone
#
# The glyph is isolated by alpha-keying the badge fill colour. Anti-aliased edge
# pixels keep a faint tint of that fill, which is invisible because the
# background layer is that exact colour.

# Repo root, derived from this script location (tool/) so it is not machine-specific.
$proj = Split-Path -Parent $PSScriptRoot
$res  = Join-Path $proj "android\app\src\main\res"

$variants  = @('', '_green', '_orange', '_pink', '_purple', '_red')
$densities = [ordered]@{ 'mdpi' = 108; 'hdpi' = 162; 'xhdpi' = 216; 'xxhdpi' = 324; 'xxxhdpi' = 432 }

# Fraction of the 108dp canvas the glyph should span. The safe zone is 72/108
# (0.667), so 0.55 leaves comfortable headroom inside it while reading as large
# as neighbouring app icons.
$GLYPH_FRACTION = 0.55

function Get-Argb($bmp) {
  $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
  $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $len  = $data.Stride * $bmp.Height
  $buf  = New-Object byte[] $len
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)
  $bmp.UnlockBits($data)
  return @{ bytes = $buf; stride = $data.Stride }
}

$backgrounds = @{}

foreach ($v in $variants) {
  $srcPath = Join-Path $res "mipmap-xxxhdpi\ic_launcher$v.png"
  if (-not (Test-Path $srcPath)) { Write-Host "skip (missing): ic_launcher$v.png"; continue }

  $src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $srcPath))
  $w = $src.Width; $h = $src.Height
  $a = Get-Argb $src
  $bytes = $a.bytes; $stride = $a.stride

  # Dominant opaque colour = the badge fill.
  $hist = @{}
  for ($y = 0; $y -lt $h; $y += 2) {
    $row = $y * $stride
    for ($x = 0; $x -lt $w; $x += 2) {
      $i = $row + $x * 4
      if ($bytes[$i + 3] -gt 200) {
        $k = "$($bytes[$i+2]),$($bytes[$i+1]),$($bytes[$i])"   # R,G,B (buffer is BGRA)
        $hist[$k] = [int]$hist[$k] + 1
      }
    }
  }
  $fillKey = ($hist.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key
  $fp = $fillKey.Split(',')
  $fr = [int]$fp[0]; $fg = [int]$fp[1]; $fb = [int]$fp[2]
  $backgrounds["ic_launcher$v"] = ('#{0:X2}{1:X2}{2:X2}' -f $fr, $fg, $fb)

  # Key on COLOUR SATURATION, not distance from the fill.
  #
  # Distance-keying kept the badge's own anti-aliased rounded edge (those pixels
  # are grey but not EXACTLY the fill), so the detected "glyph" came out 171 of
  # 192 px — the badge, not the note. The badge and its edges are neutral
  # (R≈G≈B, channel spread ~5) while the note is a saturated accent colour
  # (spread >150), so the spread separates them cleanly.
  $LO = 25; $HI = 70
  $outBuf = New-Object byte[] $bytes.Length
  $minX = $w; $minY = $h; $maxX = -1; $maxY = -1
  for ($y = 0; $y -lt $h; $y++) {
    $row = $y * $stride
    for ($x = 0; $x -lt $w; $x++) {
      $i = $row + $x * 4
      $srcA = $bytes[$i + 3]
      if ($srcA -eq 0) { continue }
      $rr = [int]$bytes[$i + 2]; $gg = [int]$bytes[$i + 1]; $bb = [int]$bytes[$i]
      $mx = [Math]::Max($rr, [Math]::Max($gg, $bb))
      $mn = [Math]::Min($rr, [Math]::Min($gg, $bb))
      $dist = $mx - $mn
      if ($dist -le $LO) { continue }
      $k = if ($dist -ge $HI) { 1.0 } else { ($dist - $LO) / ($HI - $LO) }
      $newA = [int](($srcA / 255.0) * $k * 255)
      if ($newA -le 4) { continue }
      $outBuf[$i]     = $bytes[$i]
      $outBuf[$i + 1] = $bytes[$i + 1]
      $outBuf[$i + 2] = $bytes[$i + 2]
      $outBuf[$i + 3] = [byte]$newA
      if ($newA -gt 40) {
        if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
        if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }
  $src.Dispose()

  if ($maxX -lt 0) { Write-Host "skip (no glyph found): ic_launcher$v"; continue }

  $glyph = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $gd = $glyph.LockBits((New-Object System.Drawing.Rectangle 0, 0, $w, $h), [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  [System.Runtime.InteropServices.Marshal]::Copy($outBuf, 0, $gd.Scan0, $outBuf.Length)
  $glyph.UnlockBits($gd)

  # Square crop centred on the glyph, sized so the glyph spans GLYPH_FRACTION.
  $gw = $maxX - $minX + 1; $gh = $maxY - $minY + 1
  $glyphMax = [Math]::Max($gw, $gh)
  $cropSide = [int][Math]::Round($glyphMax / $GLYPH_FRACTION)
  $cx = $minX + $gw / 2.0; $cy = $minY + $gh / 2.0
  $cropX = [int][Math]::Round($cx - $cropSide / 2.0)
  $cropY = [int][Math]::Round($cy - $cropSide / 2.0)

  Write-Host ("ic_launcher{0}: fill={1} glyph={2}x{3} crop={4} at ({5},{6})" -f $v, $backgrounds["ic_launcher$v"], $gw, $gh, $cropSide, $cropX, $cropY)

  foreach ($d in $densities.Keys) {
    $size = $densities[$d]
    $dir = Join-Path $res "mipmap-$d"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $fgBmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gr = [System.Drawing.Graphics]::FromImage($fgBmp)
    $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gr.Clear([System.Drawing.Color]::Transparent)
    $dest = New-Object System.Drawing.Rectangle 0, 0, $size, $size
    $srcR = New-Object System.Drawing.Rectangle $cropX, $cropY, $cropSide, $cropSide
    $gr.DrawImage($glyph, $dest, $srcR, [System.Drawing.GraphicsUnit]::Pixel)
    $gr.Dispose()
    $fgBmp.Save((Join-Path $dir "ic_launcher${v}_foreground.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $fgBmp.Dispose()
  }
  $glyph.Dispose()
}

# colours
$colorDir = Join-Path $res "values"
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
[void]$sb.AppendLine('<!-- Generated: adaptive-icon background layers. One flat colour per launcher')
[void]$sb.AppendLine('     variant, sampled from that icon badge fill so the glyph edges blend. -->')
[void]$sb.AppendLine('<resources>')
foreach ($k in $backgrounds.Keys) {
  [void]$sb.AppendLine("    <color name=""${k}_background"">$($backgrounds[$k])</color>")
}
[void]$sb.AppendLine('</resources>')
[System.IO.File]::WriteAllText((Join-Path $colorDir "colors.xml"), $sb.ToString())

# adaptive-icon xml per variant
$anydpi = Join-Path $res "mipmap-anydpi-v26"
if (-not (Test-Path $anydpi)) { New-Item -ItemType Directory -Path $anydpi | Out-Null }
foreach ($k in $backgrounds.Keys) {
  $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Without this file Android treats the square bitmap as a LEGACY icon: it
     shrinks it to fit inside the launcher mask and pads the rest, so the art sat
     visibly inside the icon shape while every other app reached the edge. The
     background layer below fills the canvas, so the mask itself becomes the
     icon's silhouette. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/${k}_background" />
    <foreground android:drawable="@mipmap/${k}_foreground" />
    <monochrome android:drawable="@mipmap/${k}_foreground" />
</adaptive-icon>
"@
  [System.IO.File]::WriteAllText((Join-Path $anydpi "$k.xml"), $xml)
}

Write-Host "`nwrote $($backgrounds.Count) adaptive icons + foregrounds at $($densities.Count) densities"
