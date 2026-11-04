plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.celltower.cell_tower_monitor"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.celltower.cell_tower_monitor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 9 (API 28) is the floor: the app reads cell bands and PLMN
        // strings with the API-28 telephony methods. The A10e ships 9, the
        // A14/A15 ship 13 or newer.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildFeatures {
        // Needed for BuildConfig.DEBUG, used to gate per-SIM diagnostic logs.
        buildConfig = true
        // The privileged reader's interface is AIDL: Shizuku binds a user
        // service, and the generated stub is what both sides talk through.
        aidl = true
    }

    buildTypes {
        release {
            // CI decodes the KEYSTORE_BASE64 secret and points KEYSTORE_PATH at
            // it, so every release APK is signed with the one permanent key and
            // can install over the previous version. A machine without the
            // keystore (a local `flutter run --release`) keeps debug signing.
            val ksPath = System.getenv("KEYSTORE_PATH")
            if (ksPath != null && File(ksPath).exists()) {
                signingConfig = signingConfigs.create("release").apply {
                    storeFile = File(ksPath)
                    storePassword = System.getenv("KEYSTORE_PASSWORD")
                    keyAlias = System.getenv("KEY_ALIAS")
                    keyPassword = System.getenv("KEY_PASSWORD")
                }
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // FileProvider: the in-app updater hands the downloaded APK to the package
    // installer through a content:// URI, which only a provider can open.
    implementation("androidx.core:core:1.13.1")

    // JVM unit tests for ServingMerge: the cell-pairing and held-channel rules
    // run without the framework, so they are tested off-device.
    testImplementation("junit:junit:4.13.2")

    // Carrier detail through Shizuku: `api` carries the user-service binder,
    // `provider` the content provider that hands over Shizuku's binder.
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")

    // CarrierDetail parses the user service's JSON on the JVM too, where
    // android.jar only carries stubs of org.json.
    testImplementation("org.json:json:20240303")
}

flutter {
    source = "../.."
}
