# Keep the audio_service and its inner classes
-keep class com.ryanheise.audioservice.** { *; }

# Keep your app's code (ensure the handler isn't stripped)
-keep class com.auvy.app.** { *; }

# CRITICAL: Keep just_audio classes
-keep class com.ryanheise.just_audio.** { *; }

# CRITICAL: Keep AndroidX Media classes (used for the notification)
-keep class androidx.media.** { *; }
-keep class androidx.media2.** { *; }

#  FIX FOR MEDIA PLAYER NOT SHOWING (Prevents stripping core media session & ExoPlayer)
-keep class android.support.v4.media.** { *; }
-keep class com.google.android.exoplayer2.** { *; }
-keep class androidx.media3.** { *; }

# Keep the entry point for the background isolate
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.editing.** { *; }

# ── NewPipeExtractor ─────────────────────────────────────────────────────────
# NewPipe uses reflection heavily internally;
# stripping it causes runtime crashes
# in RELEASE builds only (debug builds skip R8, so this won't show up in testing)
-keep class org.schabi.newpipe.extractor.** { *; }
-dontwarn org.schabi.newpipe.extractor.**

#  FIX FOR R8 BUILD FAILURES (Missing Classes)
-dontwarn com.google.re2j.**
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn org.mozilla.javascript.**
-dontwarn org.jsoup.**

# OkHttp (your DownloaderImpl depends on this)
-keep class okhttp3.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**

# Kotlin coroutines (used in NewPipeExtractorPlugin.kt)
-keepnames class kotlinx.coroutines.** { *; }
-dontwarn kotlinx.coroutines.**