import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Ключ подписи и пароли лежат в android/keystore.properties — файл в .gitignore.
// Если его нет (свежий клон), release просто соберётся неподписанным.
val keystoreProps = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.scvpn"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.scvpn"
        minSdk = 24
        targetSdk = 33
        versionCode = 4
        versionName = "0.2.2"
        ndk {
            // те ABI, под которые у нас есть hev .so + ядро
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
        }
        vectorDrawables.useSupportLibrary = true
    }

    signingConfigs {
        if (keystoreProps.isNotEmpty()) {
            create("release") {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Обфускация выключена намеренно: смысл проекта в том, что код
            // видно, и стектрейсы из релизной сборки должны читаться как есть.
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(files("libs/libv2ray.aar"))
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
