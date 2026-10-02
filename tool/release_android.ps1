# Build the published Android APK.
#
#   .\tool\release_android.ps1 1.3.0        # -> build\release\app-release.apk
#
# Built from a clean checkout of the current commit in a neutral folder
# (C:\auvy-release), for two reasons: a release is exactly what is committed,
# and the APK names no folder on this PC. Flutter compiles the project's own
# location into the app, so building in place would ship the user folder's
# name. The finished APK is searched for this PC's user folder and refused if
# it still appears anywhere.
#
# Signing: android\key.properties (gitignored) is copied into the checkout with
# its storeFile made absolute, so the keystore itself never moves.

param(
    [Parameter(Mandatory = $true)][string]$Version,
    # Where the clean checkout is built. Outside the user folder on purpose.
    [string]$WorkDir = "$($env:SystemDrive)\auvy-release"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# git writes progress to stderr, which Windows PowerShell 5.1 turns into an
# error under 'Stop'; run it with 'Continue' and judge it by its exit code.
function Invoke-Git {
    param([string[]]$GitArgs, [switch]$AllowFail)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "git $($GitArgs -join ' ') failed ($code): $($out | Out-String)"
    }
    return ($out | Out-String)
}

# ── The version asked for must be the version built ─────────────────────────
$gradle = Get-Content (Join-Path $root 'android\app\build.gradle.kts') -Raw
if ($gradle -notmatch 'versionName\s*=\s*"([^"]+)"') { throw 'versionName not found in build.gradle.kts' }
$built = $Matches[1]
if ($built -ne $Version) {
    throw "REFUSING - asked for $Version but android\app\build.gradle.kts says $built (bump it, commit, and run again)"
}
$null = $gradle -match 'versionCode\s*=\s*(\d+)'
$code = $Matches[1]

# ── Only committed code goes out ────────────────────────────────────────────
$status = Invoke-Git @('status', '--porcelain')
if ($status.Trim() -ne '') {
    throw 'REFUSING - commit or stash your changes first: a release is built from the committed code'
}

$kp = Join-Path $root 'android\key.properties'
if (-not (Test-Path $kp)) {
    throw 'REFUSING - android\key.properties is missing: the APK would be debug-signed and could not update the installed app'
}

# ── A clean checkout of this commit in the neutral folder ───────────────────
$null = Invoke-Git @('worktree', 'remove', '--force', $WorkDir) -AllowFail
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }
if (Test-Path $WorkDir) {
    throw "REFUSING - $WorkDir is left from an earlier run and is in use (a Gradle daemon?). Run 'cd android; .\gradlew --stop' or restart, then try again."
}
# Forgets a checkout whose folder was deleted by hand, which would otherwise
# make 'worktree add' refuse.
$null = Invoke-Git @('worktree', 'prune') -AllowFail
$null = Invoke-Git @('worktree', 'add', '--detach', $WorkDir, 'HEAD')
$commit = (Invoke-Git @('rev-parse', '--short', 'HEAD')).Trim()
Write-Host "Building $commit in $WorkDir"

try {
    # What git doesn't carry: the build's settings and the signing details.
    $envFile = Join-Path $root '.env'
    if (Test-Path $envFile) { Copy-Item $envFile (Join-Path $WorkDir '.env') }
    # Java reads key.properties as ISO-8859-1, so it is read and written that
    # way: a password with accents survives byte for byte.
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $props = [System.IO.File]::ReadAllLines($kp, $latin1)
    $changed = $false
    for ($i = 0; $i -lt $props.Length; $i++) {
        if ($props[$i] -match '^\s*storeFile\s*=\s*(.+?)\s*$') {
            $store = $Matches[1]
            # Relative paths resolve from android\app, which would be the
            # checkout's; point at the real keystore instead.
            if (-not [System.IO.Path]::IsPathRooted($store)) {
                $store = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $root 'android\app') $store))
                $props[$i] = "storeFile=$($store -replace '\\', '/')"
                $changed = $true
            }
            if (-not (Test-Path $store)) { throw "the keystore named in key.properties was not found: $store" }
        }
    }
    $kpCopy = Join-Path $WorkDir 'android\key.properties'
    if ($changed) {
        [System.IO.File]::WriteAllLines($kpCopy, $props, $latin1)
    } else {
        Copy-Item $kp $kpCopy
    }

    Push-Location $WorkDir
    try {
        & (Join-Path $WorkDir 'tool\build_release.ps1')
    } finally {
        Pop-Location
    }

    $apk = Join-Path $WorkDir 'build\app\outputs\flutter-apk\app-release.apk'
    if (-not (Test-Path $apk)) { throw 'no APK was built' }

    # ── Refuse an APK that still names this PC's user folder ────────────────
    # Searched in every file inside the APK, both slash directions, any case.
    $userDir = Split-Path -Leaf $env:USERPROFILE
    $needles = @("\Users\$userDir", "/Users/$userDir", $env:USERPROFILE, ($env:USERPROFILE -replace '\\', '/'))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($apk)
    $hits = @()
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.Length -eq 0) { continue }
            $stream = $entry.Open()
            try {
                $ms = New-Object System.IO.MemoryStream
                $stream.CopyTo($ms)
                $text = $latin1.GetString($ms.ToArray())
            } finally {
                $stream.Dispose()
            }
            foreach ($n in $needles) {
                if ($text.IndexOf($n, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $hits += $entry.FullName
                    break
                }
            }
        }
    } finally {
        $zip.Dispose()
    }
    if ($hits.Count -gt 0) {
        Write-Host 'REFUSING - the APK still names a folder under this user:' -ForegroundColor Red
        $hits | Select-Object -Unique | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
        throw 'APK not published'
    }

    $outDir = Join-Path $root 'build\release'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    # Published under this name every release.
    $final = Join-Path $outDir 'app-release.apk'
    Copy-Item $apk $final -Force
    $item = Get-Item $final
    $hash = (Get-FileHash $final -Algorithm SHA256).Hash.ToLower()
    Write-Host ''
    Write-Host "wrote $final" -ForegroundColor Green
    Write-Host "  version : $Version ($code)"
    Write-Host "  size    : $($item.Length) bytes"
    Write-Host "  sha256  : $hash"
    Write-Host "  checked : no folder under this user anywhere in the APK"
    Write-Host "  tag     : v$Version   <- the same release as the iPhone files"
} finally {
    Set-Location $root
    # The build leaves a Gradle daemon holding files in the checkout; stopped so
    # the folder can go (the next build just starts a new one).
    $gradlew = Join-Path $WorkDir 'android\gradlew.bat'
    if (Test-Path $gradlew) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $gradlew -p (Join-Path $WorkDir 'android') --stop *> $null } catch { } finally { $ErrorActionPreference = $old }
    }
    $null = Invoke-Git @('worktree', 'remove', '--force', $WorkDir) -AllowFail
    if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }
}
