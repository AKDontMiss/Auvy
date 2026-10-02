# Developing Auvy

A guide for anyone who wants to read, build or change the code. For what the
app does, see the [README](../README.md); for installing it on an iPhone, see
[INSTALL.md](../INSTALL.md).

---

## The big picture

Auvy is a Flutter app with a small native layer and a server-side helper. This
repository is the app's source release: what it takes to build, run and modify
the app. The server side (a Cloudflare Worker and the Firestore setup) is not
part of it.

| Part | Language | Lives in | Job |
| --- | --- | --- | --- |
| App | Dart (Flutter, Riverpod) | `lib/` | UI, library, search, recommendations, queue logic, backup |
| Android player | Kotlin (media3/ExoPlayer) | `android/app/src/main/kotlin/` | Playback, streaming in byte ranges, audio focus, song-recognition capture, alarm, widget |
| iOS player | Swift (AVFoundation) | `ios/Runner/` | The same platform channels as Android (see [ios/README.md](../ios/README.md)) |
| Worker | JavaScript (Cloudflare Workers) | not in this repository | Verifies sign-ins, gates access, holds the API keys, proxies metadata |
| Backup store | Firestore | your Firebase project | Encrypted, chunked library backups and Listen Together rooms |

Two design points explain most of the structure:

- **Audio never goes through the Worker.** Dart resolves a stream URL and the
  native player fetches the bytes itself, in small ranges, re-resolving when a
  URL expires.
- **The app ships no API keys.** Anything that needs a key goes through the
  Worker, which holds it as a secret.

## Where things are

```
lib/
  main.dart          app start-up, the print interceptor, the headless entry point
  core/              low-level helpers: backend config, native player bridge,
                     navigation, networking, caches
  data/              plain models (Song, Album, podcasts, radio, …)
  logic/             the player's behaviour, split into extensions of
                     PlayerNotifier: playback, queue, smart (autoplay and
                     recovery) and system (native events, sessions); plus the
                     audio cache and song-recognition fingerprinting
  providers/         Riverpod state: player, library, account, home feed, …
  services/          talking to the outside world: catalogue API, lyrics,
                     cloud sync, updater, podcasts, radio, …
  presentation/      pages/ (one file per screen) and widgets/
android/             the Kotlin player and Android integration
ios/                 the Swift player and iOS integration
tool/                build and packaging scripts
```

Good first files to read: `lib/providers/player_provider.dart` (the player's
state), `lib/core/native_audio_engine.dart` (the Dart side of the native player
channel), and `android/.../NativePlayerManager.kt` or
`ios/Runner/AuvyPlayer.swift` (the native side of it).

---

## Setting up

You need:

- **Flutter** (Dart SDK 3.10 or newer).
- **Android:** Android SDK 36 and a JDK 17. The app runs on Android 8.0+.
- **iOS:** a Mac with Xcode, CocoaPods and a Rust toolchain (see
  [ios/README.md](../ios/README.md)). The app runs on iOS 15+. `pod install`
  also brings in **libwebp**: iOS can read WebP but not write it, and custom
  covers are stored as WebP (Android writes WebP itself).

Then:

```sh
flutter pub get
```

### Configuration a fork has to supply

This repository contains no keys and points at no backend. You provide:

| What | Where | Needed for |
| --- | --- | --- |
| `.env` (copy `.env.example`) | repo root, gitignored | `AUVY_WORKER_HOST`, the host of your deployed Worker |
| `google-services.json` | `android/app/` (a `.template` is included) | Firebase on Android (cloud backup, sign-in) |
| `GoogleService-Info.plist` | `ios/Runner/` | Firebase on iOS |
| Reversed client id | `ios/Runner/Info.plist` URL scheme | Google Sign-In on iOS |
| Release keystore | `android/key.properties` | Signing Android releases (without it, release builds use the debug key) |
| Your own backend | not in this repository | Sign-in approval, backup tokens, metadata proxies: a server answering the routes the app calls (see `lib/core/backend_config.dart` and the services that use it) |

**Why `.env` matters:** keys and the Worker host are passed to the compiler as
`--dart-define` values rather than bundled as files, so nothing can be unzipped
out of the app. The catch is that a plain `flutter build` still succeeds without
them; the app then can't reach its backend, and cloud backup, update checks and
artist metadata quietly return nothing. The build scripts below read `.env` for
you.

The defines the code reads:

| Name | Used for | Required? |
| --- | --- | --- |
| `AUVY_WORKER_HOST` | the whole backend (sign-in gate, backup, updates, metadata) | yes |
| `SPOTIFY_CLIENT_ID` | a fallback for importing Spotify playlists (the secret half is refused by the build scripts: a define is readable inside the app) | no |
| `AUVY_DEBUG_LOG` | also copies log lines to the system log (see Diagnostics) | rarely |
| `AUVY_FORCE_SPLASH` | always shows the splash screen | debugging only |

---

## Building

```sh
./tool/build_release.ps1          # Android release APK (PowerShell)
./tool/build_ios.sh release       # iOS (see ios/README.md)
```

Both read `.env` and pass every line as a `--dart-define`. The Android APK ends
up in `build/app/outputs/flutter-apk/app-release.apk`.

For day-to-day work, `flutter run` is fine; add
`--dart-define=AUVY_WORKER_HOST=...` if you need the backend.

Notes:

- The release APK contains only the ARM ABIs (`arm64-v8a`, `armeabi-v7a`). Use a
  debug build for x86 emulators.
- Android release builds run R8. Test the actual release build after changing
  anything that uses reflection; problems only show up at runtime.

### Versioning and releases

- Bump `version:` in `pubspec.yaml` **and** `versionCode` / `versionName` in
  `android/app/build.gradle.kts`. `versionCode` must only ever increase: Android
  won't install a lower one over a higher one.
- Tag GitHub releases with the version, e.g. `v1.3.0`, and raise the version
  for every release: the in-app updater compares versions, and a tag without a
  build reads as build 0, so a rebuild under the same version is not offered.
- A release carries the Android `.apk`, and for iPhone an unsigned `.ipa` plus a
  `source.json` (see [ios/README.md](../ios/README.md)).
- Build published files with the release scripts, not the everyday ones:
  `./tool/release_ios.sh <version>` on a Mac (the `.ipa` and `source.json`) and
  `.\tool\release_android.ps1 <version>` on Windows (`app-release.apk`). They build the
  committed code in a neutral folder, so the app names no folder on the build
  machine, and refuse to finish if one survives. An iPhone app can only be
  built on a Mac; Apple's tools don't run anywhere else.
- Never pass a secret as a `--dart-define`: everything compiled in is readable
  inside the app. The build scripts refuse names that look like one.

---

## Tests

The test suite (over a thousand tests) lives in the private development
repository and is not part of this source release; nothing here needs it to
build, run or change the app. Run `flutter analyze` before building a change.

---

## Diagnostics

Release builds don't write to the system log (it costs real frames on hot
paths). Instead, the app can record its own activity:

**Settings → About → Record activity log**, then export it. The export is a
redacted text file (tokens and cookie values are stripped) and it works on an
ordinary release build, with no cable. Native events that matter (audio focus
changes, refused streams, network outages) are forwarded to it with a `native:`
prefix; everything else native goes to `logcat` / the Xcode console. On iPhone
the native player's diagnostics are forwarded in full (none of them fire per
chunk), so an export from an iPhone shows the Swift side too.

`AUVY_DEBUG_LOG=true` additionally mirrors every line to the system log. It is
not needed for the in-app log, and it slows the app slightly, so don't use it to
measure performance.

---

## Conventions

- **Comments explain why**, in plain language, for someone reading the code for
  the first time. Keep them short and about the code as it is now; history
  belongs in commit messages.
- **One copy of a rule.** When two places need the same decision, they call one
  function, and a test often checks that nobody reintroduces a second copy.
- **One kit per kind of screen.** The browse hubs (Podcasts, Radio,
  Audiobooks, Moods & genres) are built from
  `lib/presentation/widgets/hub_kit.dart`: titles, rails, category tiles,
  skeletons, list pages. Every selectable pill is `AuvyPill`
  (`widgets/auvy_pill.dart`). Category tiles take their look from their
  content (covers from the category itself, a colour from `colorForName`), never
  from a hand-made list of icons per name. "Go to the show / book" for a
  podcast episode or audiobook chapter goes through `widgets/spoken_word_nav.dart`.
  A new screen reuses these instead of growing its own copy.
- **Fail soft on the device, loudly in the log.** A missing platform feature
  degrades the feature, never crashes the app, and says why in the activity log.
- **Nothing secret in logs.** Tokens, cookie values, signed URL parameters and
  account identities never reach a log readable outside the app, and the
  activity log export redacts them. The activity log does name tracks (that is
  what makes it useful), which is why it is recorded only when the user turns
  it on and leaves the phone only when they export it.
