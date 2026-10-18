# iOS

Auvy runs on iPhone (iOS 15 or newer) from the same Dart code as Android. Only
the native layer differs: the Swift files in `Runner/` answer the same platform
channels the Kotlin side does, with the same method names and arguments, so the
Dart code doesn't need to know which platform it's on.

To install it on a phone, see [INSTALL.md](../docs/INSTALL.md).

## How the native side is organised

| File | Channel | What it does |
| --- | --- | --- |
| `AuvyPlayer.swift` | `com.auvy.app/native_player` | Playback. Fetches each track to a file (the next one before the current track ends), repairs it if needed, and plays it with AVQueuePlayer. Reports position, state and track ends to Dart. |
| `AuvyStreamLoader.swift` | (used by the player) | Downloads stream audio in small byte ranges and asks Dart for a fresh URL if one expires mid-download (the counterpart of Android's resolving data source in `NativePlayerManager.kt`). |
| `AuvyMP4Repair.swift` | (used by the player) | Fixes the duration of YouTube's fragmented MP4 audio, which iOS otherwise reads as twice its real length. |
| `AuvyCookies.swift` | `com.auvy.app/cookies` | YouTube sign-in in a WKWebView, and reading the session cookies (including HttpOnly ones). |
| `AuvySystemChannels.swift` | the small channels | Haptics, toasts, region, screen flags, app icon, backup files, the Files app, audio output, the wake-up alarm (AlarmKit), refresh reminders, What's New, WebP encoding for custom covers (Google's libwebp, a CocoaPods dependency: iOS can read WebP but not write it), and honest "not available" answers for Android-only features. |
| `AuvyAudioTap.swift` | (used by the player) | The equaliser (five bands, the same as Android's), the loudness trim and the level meter behind the player cover's glow when it follows the music, in an MTAudioProcessingTap on each track. Attached only while one of them is on. |
| `AuvyCommands.swift` | `com.auvy.app/commands` | Commands from outside the app's screens: Siri and Shortcuts, the widgets and Control Center, the icon's long-press menu and `auvy://` links (see below). Held until Dart is ready. |
| `AuvyIntents.swift` | (App Intents) | The Siri and Shortcuts actions and the phrases Siri knows without setup. iOS 17 and newer, except "Mark Auvy as Refreshed" (iOS 16), the last step of a SideStore refresh shortcut. |
| `../Shared/` | (both targets) | What the app and the widget share: the now-playing state in the App Group, and the widget buttons' intents. |
| `../AuvyWidget/` | (widget extension) | The home-screen, lock-screen and Control Center widgets. iOS 17 and newer (Control Center: 18). |

Why tracks are fetched to a file rather than streamed: AVFoundation parsed
YouTube's audio as double its real length when it arrived through a streaming
resource loader. A complete, repaired file on disk plays correctly.

## Differences from Android

iOS doesn't allow everything the Android app does. These features are absent
or reduced on iPhone:

- **Identifying audio from another app** isn't possible (iOS has no screen-audio
  capture). Song recognition uses the microphone instead.
- **The quick-settings tile** is Android's; the iPhone has a Control Center
  button instead (iOS 18).
- **The wake-up alarm** needs iOS 26 or newer (AlarmKit), and earlier versions
  hide it. iOS rings it itself, over the lock screen and through silent mode,
  with the first 30 seconds of the song rather than the whole track, and there
  is no snooze yet (it would need a Live Activity widget).
- **Pitch and skip-silence** aren't supported by AVPlayer; the app reports
  them as unavailable. The equaliser and loudness normalisation work (through an
  audio tap, AuvyAudioTap.swift).
- **Choosing the audio output** goes through the system AirPlay / Bluetooth
  picker.
- **Updates** can't be installed by the app itself; it opens SideStore instead
  (see docs/INSTALL.md).

**What's New notifications** with Auvy closed use a background app refresh
task (`com.auvy.app.whatsnew`, read back from Info.plist at run time because
SideStore renames it for each Apple ID); iOS decides when it runs, typically a
few times a day for an app in use, so a notification can come hours after a
release.

**Siri, Shortcuts and widgets** (iOS 17 and newer). Siri knows phrases such as
"Shuffle my liked songs in Auvy", "Play Weekly Discovery in Auvy", "Play
\<playlist\> in Auvy", "Search Auvy", "Skip this song in Auvy" and "Like this
song in Auvy" without any setup; the Shortcuts app has the same actions, plus
"Play a Music Link" for a Share Sheet shortcut. The widgets' buttons run inside
Auvy (AudioPlaybackIntents), so they work from the home screen, the lock screen
and Control Center. If iOS has fully closed Auvy, a command opens it and then
plays. `auvy://` links do the same from anywhere: `auvy://collection/liked?shuffle=1`,
`auvy://playlist?name=…`, `auvy://search?q=…`, `auvy://open?url=<music link>`,
`auvy://toggle`, `auvy://next`.

**Mark Auvy as Refreshed** (iOS 16 and newer) is the one action that isn't
about playing. A SideStore refresh can't be seen from inside the app, so a
Shortcuts automation that runs SideStore's "Refresh All Apps" ends with this
action: it records the refresh and moves the expiry reminders, without opening
Auvy. The steps are in [INSTALL.md](../docs/INSTALL.md#refreshing-automatically).

**Links from other apps.** A free Apple ID can't give Auvy a share
extension (it would be a fourth app next to SideStore, Auvy and its widget), so
on iPhone links come in three ways: copy a link and open Auvy, which offers to
open it (`UIPasteboard.detectPatterns` checks for a link without reading it,
so iOS's paste prompt only appears when you tap Open); paste it into Search;
or an "Open in Auvy" Shortcut in the Share menu (Settings → Other apps has the
steps). Android adds "Share → Auvy".

**The widget's data** travels through an App Group. The published IPA carries
it in an ad-hoc signature (tool/package_sideload_ipa.sh) and SideStore renames
it for the installing Apple ID's team; the app reads the actual group from its
own signature (AuvyNowPlayingStore.swift). On a free Apple ID the widget takes
one of the three app slots; [INSTALL.md](../docs/INSTALL.md) explains the choice.

**Large settings live in files.** iOS's settings store has a 4 MB limit, and
past it iOS stops saving it reliably ("Attempting to store >= 4194304 bytes …
direct mode"). The library, listening history and taste data are kept in files
under Application Support instead (lib/core/large_prefs_store.dart), behind the
same SharedPreferences API.

iPhone only: **refresh reminders.** The SideStore signature lasts 7 days on a
free Apple ID, and Auvy stops opening if a renewal is missed. Auvy reads the
expiry from its own provisioning profile and, once allowed, schedules two
local notifications, a quiet one a day before it and a normal one 3 hours
before; iOS delivers them whether Auvy is open, in the background or closed. A
card on Home says the same once two days remain. Settings → Updates →
SideStore refresh shows the date and how it was last refreshed, and holds the
reminders switch, "I refreshed by hand" and an in-app walk-through for the
automation (the shortcut's actions by name, buttons into Shortcuts, and a
check that the first run reached Auvy).

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
./tool/release_ios.sh 1.4.1    # -> build/sideload/app-release.ipa + source.json
```

It builds the committed code (commit first) in a neutral folder, because
Flutter compiles the project's location into the app and a build in your own
folder would carry its name, then packages it with
`tool/package_sideload_ipa.sh`. That writes the release's `source.json` (the
SideStore source) from the IPA itself and prints the release tag to use; it
refuses if the version you pass is not the one that was built, or if a folder
name survives.

The packaging script strips the development signature, because a signed
build contains the developer's team name, device IDs and Apple ID email.
SideStore re-signs the app with each user's own Apple ID when they install it.
