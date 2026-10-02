# iOS

Auvy runs on iPhone (iOS 15 or newer) from the same Dart code as Android. Only
the native layer differs: the Swift files in `Runner/` answer the same platform
channels the Kotlin side does, with the same method names and arguments, so the
Dart code doesn't need to know which platform it's on.

To install it on a phone, see [INSTALL.md](../INSTALL.md).

## How the native side is organised

| File | Channel | What it does |
| --- | --- | --- |
| `AuvyPlayer.swift` | `com.auvy.app/native_player` | Playback. Fetches each track to a file (the next one before the current track ends), repairs it if needed, and plays it with AVQueuePlayer. Reports position, state and track ends to Dart. |
| `AuvyStreamLoader.swift` | (used by the player) | Downloads stream audio in small byte ranges and asks Dart for a fresh URL if one expires mid-download (the counterpart of `ChunkedDataSource.kt`). |
| `AuvyMP4Repair.swift` | (used by the player) | Fixes the duration of YouTube's fragmented MP4 audio, which iOS otherwise reads as twice its real length. |
| `AuvyCookies.swift` | `com.auvy.app/cookies` | YouTube sign-in in a WKWebView, and reading the session cookies (including HttpOnly ones). |
| `AuvySystemChannels.swift` | the small channels | Haptics, toasts, region, screen flags, app icon, backup files, the Files app, audio output, the wake-up alarm (AlarmKit), refresh reminders, What's New, WebP encoding for custom covers (Google's libwebp, a CocoaPods dependency: iOS can read WebP but not write it), and honest "not available" answers for Android-only features. |

Why tracks are fetched to a file rather than streamed: AVFoundation parsed
YouTube's audio as double its real length when it arrived through a streaming
resource loader. A complete, repaired file on disk plays correctly.

## Differences from Android

iOS doesn't allow everything the Android app does. These features are absent
or reduced on iPhone:

- **Identifying audio from another app** isn't possible (iOS has no screen-audio
  capture). Song recognition uses the microphone instead.
- **The quick-settings tile and home-screen widget** have no iOS version.
- **The wake-up alarm** needs iOS 26 or newer (AlarmKit), and earlier versions
  hide it. iOS rings it itself, over the lock screen and through silent mode,
  with the first 30 seconds of the song rather than the whole track, and there
  is no snooze yet (it would need a Live Activity widget).
- **Equalizer, pitch, skip-silence and loudness normalization** aren't
  supported by AVPlayer; the app reports them as unavailable.
- **Choosing the audio output** goes through the system AirPlay / Bluetooth
  picker.
- **Updates** can't be installed by the app itself; it opens SideStore instead
  (see INSTALL.md).

**What's New notifications** with Auvy closed use a background app refresh
task (`com.auvy.app.whatsnew`); iOS decides when it runs, typically a few times
a day for an app in use, so a notification can come hours after a release.

iPhone only: **refresh reminders.** The SideStore signature lasts 7 days on a
free Apple ID, and Auvy stops opening if a renewal is missed. Auvy reads the
expiry from its own provisioning profile and, once allowed, schedules local
notifications 2 days, 1 day and 3 hours before it; iOS delivers them whether
Auvy is open, in the background or closed. A card on Home says the same once
two days remain. Settings → Updates → Refresh reminders turns them off.

What does work the same: search, library, playlists, downloads, lyrics,
podcasts, radio, audiobooks, cloud backup, Listen Together, background
playback and lock-screen controls, and accent-coloured app icons (applied
when the app goes to the background, so iOS doesn't show an alert).

Downloads, saved covers and exported backups appear in the Files app under
**On My iPhone → Auvy**. The app's internal caches are kept out of sight.

## Building

You need a Mac with Xcode, CocoaPods, and a Rust toolchain (the
`metadata_god` plugin compiles Rust with Cargokit). Then:

```sh
flutter pub get
cd ios && pod install && cd ..
```

Before the first build:

1. **`ios/Runner/GoogleService-Info.plist`**: from your own Firebase project
   (add an iOS app with bundle id `com.auvy.app`). It isn't in this repository.
   Without it, Firebase fails on launch.
2. **Google Sign-In URL scheme**: in `Runner/Info.plist`, replace the
   placeholder reversed client id with the `REVERSED_CLIENT_ID` from your
   `GoogleService-Info.plist`.
3. **Signing**: in Xcode, Runner → Signing & Capabilities → your team.
4. **`.env`** in the repository root, copied from `.env.example`, with at least
   `AUVY_WORKER_HOST` (your own backend's host; the Worker isn't published).
   It's gitignored, so it doesn't come with a clone.

Then build:

```sh
./tool/build_ios.sh release        # passes the keys from .env to the build
```

A plain `flutter build ios` also works, but without the keys the app can't reach
its backend.

## Packaging for SideStore

```sh
./tool/build_ios.sh release
./tool/package_sideload_ipa.sh 1.3.0    # -> build/sideload/app-release.ipa + source.json
```

It also writes the release's `source.json` (the SideStore source) from the
IPA itself, and prints the release tag to use. It refuses if the version you
pass is not the one that was built.

The packaging script strips the development signature, because a signed
build contains the developer's team name, device IDs and Apple ID email.
SideStore re-signs the app with each user's own Apple ID when they install it.
