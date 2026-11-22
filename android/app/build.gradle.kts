import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Where the permanent signing key lives.
//
// CI decodes the KEYSTORE_BASE64 secret and exports KEYSTORE_PATH, along with
// KEYSTORE_PASSWORD, KEY_ALIAS and KEY_PASSWORD. A local machine can export
// those same variables, or drop the keystore and an `android/key.properties`
// (storeFile, storePassword, keyAlias, keyPassword) beside this build — both
// are git-ignored. Either way the build is signed with the one key the released
// APKs use, so a build made here installs over the released app and the
// released app installs back over it.
val signingProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingSecret(environment: String, property: String): String? =
    System.getenv(environment) ?: signingProperties.getProperty(property)

val permanentKey = signingSecret("KEYSTORE_PATH", "storeFile")?.let { path ->
    val file = File(path)
    (if (file.isAbsolute) file else rootProject.file(path)).takeIf { it.exists() }
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

    signingConfigs {
        if (permanentKey != null) {
            create("permanent") {
                storeFile = permanentKey
                storePassword = signingSecret("KEYSTORE_PASSWORD", "storePassword")
                keyAlias = signingSecret("KEY_ALIAS", "keyAlias")
                keyPassword = signingSecret("KEY_PASSWORD", "keyPassword")
            }
        }
    }

    buildTypes {
        // Debug builds carry the permanent key as well. That is the whole point:
        // the phone has the released app on it, so a test build has to go over
        // that app rather than demand it be uninstalled first — which would take
        // the Shizuku grant, the saved settings and the update history with it.
        // Without the key both build types keep debug signing, as before.
        getByName("debug") {
            if (permanentKey != null) {
                signingConfig = signingConfigs.getByName("permanent")
            }
        }
        release {
            signingConfig = if (permanentKey != null) {
                signingConfigs.getByName("permanent")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 has to keep the Shizuku user service intact: it is started by
            // reflection from another process, by class name and no-arg
            // constructor, neither of which survives shrinking on its own.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
