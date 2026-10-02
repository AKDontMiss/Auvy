# Keep the audio_service and its inner classes
-keep class com.ryanheise.audioservice.** { *; }

# Keep the app's own classes (entry points referenced from the manifest and JNI)
-keep class com.auvy.app.** { *; }

# just_audio (not a current dependency; the rule is harmless)
-keep class com.ryanheise.just_audio.** { *; }

# AndroidX media classes (used for the media notification)
-keep class androidx.media.** { *; }
-keep class androidx.media2.** { *; }

# Media session and ExoPlayer classes; stripping them hides the media player
-keep class android.support.v4.media.** { *; }
-keep class com.google.android.exoplayer2.** { *; }
-keep class androidx.media3.** { *; }

# Keep the entry point for the background isolate
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.editing.** { *; }

# NewPipeExtractor (not a current dependency). It uses reflection, and R8
# stripping breaks it at runtime in release builds only.
-keep class org.schabi.newpipe.extractor.** { *; }
-dontwarn org.schabi.newpipe.extractor.**

# Silence R8 missing-class errors for optional dependencies
-dontwarn com.google.re2j.**
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn org.mozilla.javascript.**
-dontwarn org.jsoup.**

# OkHttp
-keep class okhttp3.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**

# Kotlin coroutines
-keepnames class kotlinx.coroutines.** { *; }
-dontwarn kotlinx.coroutines.**