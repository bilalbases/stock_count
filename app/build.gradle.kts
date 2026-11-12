plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.devtools.ksp")
}

android {
    namespace = "com.example.stockcount"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.example.stockcount"
        minSdk = 24
        targetSdk = 35
        // Each GitHub build gets a higher number so it installs as an update over the old one.
        // versionName is set by hand (the version shown in the app and on the release);
        // versionCode follows the GitHub build number so every build is a newer update.
        val run = System.getenv("GITHUB_RUN_NUMBER")?.toIntOrNull() ?: 1
        versionCode = 100 + run
        versionName = "1.29"
        // Google Sheet upload defaults, taken from the GitHub repo secrets SHEET_URL / SHEET_KEY.
        fun quoted(name: String) = "\"" + (System.getenv(name) ?: "").replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        buildConfigField("String", "SHEET_URL", quoted("SHEET_URL"))
        buildConfigField("String", "SHEET_KEY", quoted("SHEET_KEY"))
    }

    // One fixed signing key for every build, so a new APK installs over the old one
    // (keeps counts, material list and settings; no uninstall needed).
    // Fixed key kept in the repo (owner chose this) so every build installs over the previous one.
    val keyFile = file("stockcount.jks")
    signingConfigs {
        create("fixed") {
            storeFile = keyFile
            storePassword = "stockcount"
            keyAlias = "stockcount"
            keyPassword = "stockcount"
        }
    }

    buildTypes {
        debug {
            if (keyFile.exists()) signingConfig = signingConfigs.getByName("fixed")
        }
        release {
            isMinifyEnabled = false
            if (keyFile.exists()) signingConfig = signingConfigs.getByName("fixed")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    // Barcode scanning that works offline: ML Kit model bundled inside the app + CameraX
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    val camerax = "1.4.1"
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")
}
