# Build the release APK with every key the app expects.
#
#   .\tool\build_release.ps1
#
# Optional extra defines, for diagnostic builds that must still carry the keys:
#
#   .\tool\build_release.ps1 -ExtraDefine AUVY_DEBUG_LOG=true
#
# AUVY_DEBUG_LOG=true re-enables Dart print() in a release build (release
# normally drops every print; see the Zone in main.dart).
#
# Why this script: the app's settings (the Worker host, the YouTube client id)
# are passed as --dart-define, compiled into the binary, rather than bundled as
# assets. A plain `flutter build apk --release` builds without them and the app
# cannot reach its backend. This reads .env and passes every value through.
#
# Security: everything passed here ends up readable inside the APK, so a name
# that looks like a secret (SECRET, PASSWORD, PRIVATE, TOKEN, API_KEY) is
# refused: secrets live on the Worker, never in the app. .env is gitignored and
# not bundled (don't add it to pubspec assets), and only key names are printed.
#
# For the published APK use tool\release_android.ps1, which builds from a clean
# checkout in a neutral folder so the APK names no folder on this PC.

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
        if ($name -match '(?i)SECRET|PASSWORD|PRIVATE|TOKEN|API_KEY') {
            throw "REFUSING - '$name' looks like a secret, and every define is readable inside the APK. Keep it on the Worker."
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

# The Rust library (metadata_god) compiles its crates' source paths into its
# panic messages. Remapped so the APK names no folder under this user's home.
# CARGO_ENCODED_RUSTFLAGS, not RUSTFLAGS: the plugin's Android build sets the
# encoded variable itself (keeping what is already in it), which makes Cargo
# ignore RUSTFLAGS.
$env:CARGO_ENCODED_RUSTFLAGS = "--remap-path-prefix=$($env:USERPROFILE)=~"

Write-Host ''
Write-Host 'Building release APK...'
# ARM only: build.gradle.kts drops x86_64 from the APK anyway, so compiling it
# (the Dart snapshot and the metadata_god Rust library) was build time for
# nothing. Emulators use a debug build.
& flutter build apk --release --target-platform android-arm,android-arm64 @defines
if ($LASTEXITCODE -ne 0) { throw "flutter build failed with exit code $LASTEXITCODE" }

$apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
if (Test-Path $apk) {
    $mb = [math]::Round((Get-Item $apk).Length / 1MB, 1)
    Write-Host ''
    Write-Host "Built $apk ($mb MB)"
}
