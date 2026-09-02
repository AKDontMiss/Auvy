# Build the release APK with every key the app expects.
#
# Optional extra defines, for diagnostic builds that must still carry the keys:
#
#   .\tool\build_release.ps1 -ExtraDefine AUVY_DEBUG_LOG=true
#
# AUVY_DEBUG_LOG=true re-enables Dart print() in a release build. Release normally
# swallows every print (see the Zone in main.dart — they are synchronous platform
# writes on hot paths and cost real frames), which also means a release APK cannot
# be traced. Passing it here keeps the keys, unlike a bare `flutter build apk`.
#
# WHY THIS EXISTS
# ---------------
# API keys are passed as --dart-define, not bundled as assets: an asset ships in
# the APK as plaintext and comes out with one unzip. The define is baked into the
# AOT binary instead. That is not encryption — a determined person can still find
# a string in a binary — but it removes the one-command extraction.
#
# The cost of that design is that `flutter build apk --release` on its own
# produces a KEYLESS build, silently. It compiles, installs and runs; artist bios
# are just blank, onboarding suggests no similar artists, and one recommendation
# source is dead, with no error to explain any of it. This script closes that gap
# by reading .env and passing everything through.
#
#   .\tool\build_release.ps1
#
# SECURITY
# --------
# .env is gitignored and NOT bundled into the APK — do not add it to pubspec
# assets. This script never prints a key value, only which names it found.

param(
    # Each entry is a bare NAME=VALUE, appended as an extra --dart-define.
    [string[]]$ExtraDefine = @()
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$envFile = Join-Path $root '.env'
$defines = @()

if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }
        $name = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        # Strip surrounding quotes if the file uses them.
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($value -eq '') {
            Write-Host "  $name is empty in .env - skipping"
            continue
        }
        $defines += "--dart-define=$name=$value"
        Write-Host "  $name supplied ($($value.Length) chars)"
    }
} else {
    Write-Host "No .env found. Building WITHOUT keys - Last.fm features will be inert."
}

if ($defines.Count -eq 0) {
    Write-Host "WARNING: no keys are being passed to this build."
}

# Extra defines last, so a caller can deliberately override a .env value.
foreach ($extra in $ExtraDefine) {
    if ($extra.Trim() -eq '') { continue }
    $defines += "--dart-define=$extra"
    # Name only. An extra define is not expected to be a secret, but this script
    # has a rule about never printing values and it holds here too.
    Write-Host "  extra define: $($extra.Split('=')[0])"
}

Write-Host ''
Write-Host 'Building release APK...'
& flutter build apk --release @defines
if ($LASTEXITCODE -ne 0) { throw "flutter build failed with exit code $LASTEXITCODE" }

$apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
if (Test-Path $apk) {
    $mb = [math]::Round((Get-Item $apk).Length / 1MB, 1)
    Write-Host ''
    Write-Host "Built $apk ($mb MB)"
}
