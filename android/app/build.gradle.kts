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
        // versionName — то, что видит человек; versionCode Android требует
        // только возрастающим, иначе установка поверх старой сборки не пройдёт.
        versionCode = 7
        versionName = "0.0.0"
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

    // Проверки чистой логики: гоняются на JVM, устройство не нужно.
    testImplementation("junit:junit:4.13.2")
    // org.json на JVM — заглушка, все методы возвращают null. Настоящая
    // реализация нужна, чтобы формат обмена проверялся, а не имитировался.
    testImplementation("org.json:json:20240303")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.google.zxing:core:3.5.3")
    // Готовый экран сканирования с камерой: своя реализация превью и
    // автофокуса ради одной кнопки не окупается.
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
