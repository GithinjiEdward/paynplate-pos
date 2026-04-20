import java.text.SimpleDateFormat
import java.util.Date

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.eatery_pos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.eatery_pos"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Replace this later with your real release signing config
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

/**
 * Creates a uniquely named APK after release build finishes.
 * Output example:
 * PlayNPlate_v1.0_3_20260418_153210.apk
 */
afterEvaluate {
    tasks.matching { it.name == "assembleRelease" }.configureEach {
        doLast {
            val apkDir = file("$buildDir/outputs/flutter-apk")
            val sourceApk = file("$apkDir/app-release.apk")

            if (!sourceApk.exists()) {
                println("⚠️ app-release.apk not found at: ${sourceApk.absolutePath}")
                return@doLast
            }

            val versionNameValue = android.defaultConfig.versionName ?: "1.0"
            val versionCodeValue = android.defaultConfig.versionCode ?: 1
            val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss").format(Date())

            val targetApk = file(
                "$apkDir/PlayNPlate_v${versionNameValue}_${versionCodeValue}_$timestamp.apk"
            )

            sourceApk.copyTo(targetApk, overwrite = true)

            println("✅ Custom APK created: ${targetApk.absolutePath}")
        }
    }
}