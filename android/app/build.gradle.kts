import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Load release-signing credentials from android/key.properties (kept out of git).
// If the file is absent the release build safely falls back to debug-signing, so
// the project still builds for anyone who hasn't set up a keystore yet.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.auvy.app"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.auvy.app"
        minSdk = 26
        targetSdk = 36
        // versionCode must only ever increase: Android refuses to install a lower
        // versionCode over a higher one (the only way round is an uninstall, which
        // wipes local data).
        //
        // When releasing, bump BOTH this and `version:` in pubspec.yaml (Gradle does
        // not read the pubspec value), and tag the release `v<name>+<code>`, e.g.
        // v1.2.9+2090. A bare `v1.2.9` parses as build 0 and the in-app updater will
        // never offer it.
        versionCode = 2100
        versionName = "1.3.0"

        // Only the ARM ABIs are shipped: arm64-v8a for modern phones and
        // armeabi-v7a for 32-bit ones. x86_64 (emulators, some Chromebooks) is
        // dropped to save ~25MB; use a debug build for emulators.
        //
        // abiFilters only covers NDK output; Flutter's own libflutter.so/libapp.so
        // are added as jniLibs, so the packaging block below is what actually drops
        // x86_64.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String

                // Signature schemes.
                //
                // v3 is enabled because it supports key rotation; without it this keystore
                // would be the only key that could ever update Auvy. The scheme is recorded
                // in each APK's signature, so it has to be on from the start.
                //
                // v1 (old JAR signing) stays off: it's superseded since Android 7 and minSdk
                // is 26.
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
                // v4 is an incremental-install optimisation (ADB streaming). It
                // emits a separate .idsig alongside the APK and costs nothing when
                // unused, but it is left off so a release is exactly ONE file to
                // publish and verify.
                enableV4Signing = false
            }
        }
    }

    // Strip the x86 slices at packaging time, the only stage that sees every
    // native library regardless of where it came from.
    packaging {
        jniLibs {
            excludes += listOf("lib/x86/**", "lib/x86_64/**")
        }
    }

    buildTypes {
        release {
            // If android/key.properties exists we sign with the real release key
            // (proper, updatable release). Otherwise we fall back to the debug key
            // so the project still builds — that APK is sideload-only, NOT a real
            // release. Provide key.properties + auvy-release.jks to sign for real.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
            // R8 minification: shrinks the release build and obfuscates the Kotlin
            // layer. Keep rules (media3, audio_service, NewPipe, OkHttp, the app's own
            // classes) are in proguard-rules.pro.
            //
            // Test the actual release build after changing this: R8 problems show up at
            // runtime in reflection-based code, never in debug builds.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // 16 KB page-size compatibility (Android 15+). useLegacyPackaging=false makes
    // AGP store .so files uncompressed and page-aligned inside the APK (zipalign
    // -P 16 under AGP 8.3+), which is required so the loader can mmap native libs
    // directly on 16 KB-page devices.
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    
    // Explicit Media3 components required by native audio interception loops
    implementation("androidx.media3:media3-exoplayer:1.2.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.2.1") // HLS (.m3u8) live radio
    implementation("androidx.media3:media3-common:1.2.1")
    implementation("androidx.media3:media3-datasource:1.2.0")
    // media3 SimpleCache/CacheDataSource live in media3-datasource; the SimpleCache
    // index needs a DatabaseProvider from media3-database (the streaming play-cache
    // for the lazy ResolvingDataSource — see NativePlayerManager).
    implementation("androidx.media3:media3-database:1.2.1")
    
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
}