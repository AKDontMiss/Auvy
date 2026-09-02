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
        // ── 1.2.8 / 2080 — CONTINUING THE REAL VERSION LINE ─────────────────
        //
        // versionCode MUST ONLY EVER INCREASE. This project already learned
        // that the expensive way.
        //
        // History worth keeping, because the reasoning matters more than the
        // numbers: this was briefly reset to 1.0.0 / 1000 to mark "the first
        // official release". That looked tidy and was wrong on two counts.
        //
        //  1. 1000 is BELOW the 2070 already sideloaded, and Android refuses to
        //     install a lower versionCode over a higher one. Moving a device onto
        //     it required `adb uninstall`, which wipes local data — and
        //     allowBackup="false" means there is no adb-backup fallback either.
        //  2. UpdaterService._isNewerVersion compares version SEGMENTS, so 1.0.0
        //     reads as older than 1.2.7. Anything still on 1.2.7 would never have
        //     been offered the "newer" release at all.
        //
        // 2080 clears both: above 2070 (the last real release) and above 1000
        // (the reset build), so it installs cleanly over either with no uninstall
        // and the updater offers it to every existing install.
        //
        // A marketing-style "1.0.0" is not worth a version line that goes
        // backwards. Bump BOTH this and `version:` in pubspec.yaml — Gradle does
        // not read the pubspec value — and tag the release `v<name>+<code>`
        // (v1.2.8+2080); a bare `v1.2.8` parses as build 0 and the updater
        // silently never offers it.
        versionCode = 2080
        versionName = "1.2.8"

        // ── Ship ONE architecture ───────────────────────────────────────────
        //
        // The APK carried arm64-v8a, armeabi-v7a AND x86_64: ~23MB, ~21MB and
        // ~25MB of native code, of which any given phone loads exactly one set
        // and ignores the rest. That is 82.7MB downloaded through the in-app
        // updater to install about 37MB of useful bytes.
        //
        // BOTH ARM targets stay. arm64-v8a covers every modern phone;
        // armeabi-v7a covers the 32-bit ones, which still turn up in a group of
        // friends with mixed hardware. Dropping it would save ~21MB and then
        // fail to install on those devices with nothing but "App not installed"
        // — Android never says the ABI is the reason, so it would be a horrible
        // thing to debug from a text message.
        //
        // Only x86_64 goes: that is emulators and a handful of Chromebooks, and
        // no phone will ever load it. ~25MB for nobody.
        //
        // Do NOT add x86_64 back to test on an emulator — build a debug APK
        // for that instead; this filter applies to the release users download.
        // abiFilters alone does NOT do it. It governs NDK/cargokit output
        // (libmetadata_god.so), but Flutter's Gradle plugin injects
        // libflutter.so and libapp.so as jniLibs, which this never sees — the
        // first attempt left all three ABIs in the APK and the size unchanged.
        // The packaging block further down is what actually drops x86_64.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        
        // Optimize loop mechanics down to the native metal level
        externalNativeBuild {
            cmake {
                cppFlags("-std=c++17 -O3 -frtti -fexceptions")
                arguments("-DANDROID_STL=c++_shared")
            }
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String

                // ── SIGNATURE SCHEMES ────────────────────────────────────────
                //
                // The built APK verified with v2 ONLY (checked with apksigner:
                // "v3 scheme: false"). v2 is valid and secure, but v3 is what
                // supports KEY ROTATION — and without it, this keystore is the
                // only key that can ever update Auvy. If it were lost or
                // compromised, every existing install would be stranded: Android
                // refuses an update signed by a different key, so the only path
                // is uninstall-and-reinstall, which wipes the user's local data.
                //
                // Enabled now rather than later because the scheme is recorded in
                // the SIGNATURE of each APK — turning it on for a future release
                // does not retrofit rotation onto installs of this one.
                //
                // v1 stays OFF: it is the old JAR signing, superseded since
                // Android 7, and minSdk here is 26. Leaving it off also means
                // there is no META-INF/*.RSA to mislead a future audit into
                // reading the wrong certificate.
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

    // Strip the x86 slices at PACKAGING time — the only stage that sees every
    // native library, whoever put it there. Verified by listing lib/ in the
    // built APK; anything less and x86_64 quietly rides along.
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
            // ── R8 ON ────────────────────────────────────────────────────────
            //
            // Was false, which meant the shipped APK carried the Kotlin layer with
            // class and method names intact: anyone could decompile it and read
            // how session handling, cookie storage and the player work in
            // near-source form. Dart is AOT-compiled so app logic was never
            // readable, but the native layer was — and that is exactly the part
            // worth reading if you are probing for a way in.
            //
            // proguard-rules.pro was already written FOR R8 (its own comments talk
            // about release-only stripping breaking NewPipe's reflection), so the
            // keep rules for media3, audio_service, NewPipe, OkHttp and the app's
            // own classes were in place and simply never being applied.
            //
            // MUST be verified by RUNNING the release build, not just by it
            // compiling: R8 failures are runtime failures in code paths that use
            // reflection, and a debug build never exercises them.
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
    // directly on 16 KB-page devices. Our own native_dsp.so is additionally
    // 16 KB-segment-aligned via the linker flags in cpp/CMakeLists.txt.
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    // Direct CMake script path evaluation to wire native C++ DSP compilation
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
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