import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.psyche.omnichat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    packaging {
        // PRoot ships in jniLibs and must be extracted to nativeLibraryDir,
        // where SELinux permits executing app-installed libraries (P2-5).
        jniLibs {
            useLegacyPackaging = true
        }
    }

    androidResources {
        // Already-compressed rootfs tarball: do not deflate it again. `.gz`
        // must not be listed (AAPT2 gunzips it and strips the suffix); the
        // payload therefore ships as `.tgz`.
        noCompress += "tgz"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.psyche.omnichat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Releases are universal APKs. Legacy `--split-per-abi` builds used
        // versionCode + 1000/2000/4000 for arm32/arm64/x86_64, and a 1.28.0
        // build shipped with 7112, so a plain universal code (112) is treated
        // as a downgrade by devices that installed either one. Keep the
        // universal code above every code already seen on devices while
        // preserving the semantic build number in pubspec.yaml.
        versionCode = flutter.versionCode + 8000
        versionName = flutter.versionName
    }

    val keystorePropertiesFile = rootProject.file("key.properties")
    val keystoreProperties = Properties()
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(keystorePropertiesFile.inputStream())
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        getByName("release") {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    // Note: Splits configuration removed temporarily to avoid conflicts with Flutter's build process
    // To build ARM64 only, use flutter build apk --target-platform android-arm64

}

flutter {
    source = "../.."
}

dependencies {
    // Custom Tabs + AuthTab for the Android provider OAuth sign-in window.
    implementation("androidx.browser:browser:1.9.0")
    // P2-5: `.tar.xz` rootfs support in SafeTarExtractor.
    implementation("org.tukaani:xz:1.10")
    // P2-5: JVM tests for the PRoot argv/guest-path contract.
    testImplementation("junit:junit:4.13.2")
    // Required for core library desugaring (used by flutter_local_notifications)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

// P2-5: the payloads are pinned + SHA256-verified by
// `android/scripts/fetch-sandbox.sh` and deliberately not committed to Git
// (GPL/LGPL proot binaries + the large distro rootfs). Fail the build with a
// clear message instead of silently shipping an APK without a sandbox.
val ensureSandboxFetched = tasks.register("ensureSandboxFetched") {
    group = "omnichat"
    doLast {
        val jniDir = layout.projectDirectory.dir("src/main/jniLibs/arm64-v8a").asFile
        val sandbox = layout.projectDirectory.dir("src/main/assets/sandbox").asFile
        val required = listOf(
            File(jniDir, "libproot_exec.so"),
            File(jniDir, "libproot_loader.so"),
            File(jniDir, "libandroid-shmem.so"),
            File(sandbox, "lib/libtalloc.so.2"),
            File(sandbox, "rootfs-ubuntu-base-24.04.4-arm64.tgz"),
            File(sandbox, "manifest.json"),
        )
        val missing = required.filterNot { it.isFile }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "Android sandbox payload missing: " +
                    missing.joinToString { it.path } +
                    " — run `bash android/scripts/fetch-sandbox.sh` from the " +
                    "android directory before assembling.",
            )
        }
    }
}

tasks.named("preBuild") { dependsOn(ensureSandboxFetched) }

// Disable lint checks to resolve file access issues
android {
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}
