plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseStore = providers.environmentVariable("NEAR_TRANSFER_KEYSTORE")
val releaseStorePassword = providers.environmentVariable("NEAR_TRANSFER_STORE_PASSWORD")
val releaseAlias = providers.environmentVariable("NEAR_TRANSFER_KEY_ALIAS")
val releaseKeyPassword = providers.environmentVariable("NEAR_TRANSFER_KEY_PASSWORD")
val canSign = listOf(releaseStore, releaseStorePassword, releaseAlias, releaseKeyPassword)
    .all { it.isPresent }

android {
    namespace = "app.neartransfer.near_transfer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.neartransfer.near_transfer"
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (canSign) {
        signingConfigs.create("release") {
            storeFile = file(releaseStore.get())
            storePassword = releaseStorePassword.get()
            keyAlias = releaseAlias.get()
            keyPassword = releaseKeyPassword.get()
        }
    }
    buildTypes {
        release {
            if (canSign) signingConfig = signingConfigs.getByName("release")
        }
    }
}

// Keep release failures explicit and never fall back to the debug certificate.
tasks.register("checkReleaseSigning") {
    doLast {
        check(canSign) { "Set NEAR_TRANSFER_KEYSTORE, NEAR_TRANSFER_STORE_PASSWORD, NEAR_TRANSFER_KEY_ALIAS, and NEAR_TRANSFER_KEY_PASSWORD." }
    }
}
tasks.configureEach {
    if (name == "preReleaseBuild") dependsOn("checkReleaseSigning")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
