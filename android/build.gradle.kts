plugins {
    id("com.android.application") version "8.6.1" apply false
    id("org.jetbrains.kotlin.android") version "1.9.25" apply false
}

// Каталог сборки на macOS уносится из проекта.
//
// Репозиторий часто лежит в ~/Documents, а её синхронизирует iCloud: он
// создаёт рядом копии вида «MainActivity$ServerAdapter 2.dex», и D8 падает на
// «Type is defined multiple times». Ошибка выглядит как поломка кода, хотя код
// ни при чём, и повторяется после каждой чистки.
//
// На Windows и Linux ничего не меняется.
if (System.getProperty("os.name").startsWith("Mac")) {
    val outside = File(System.getProperty("user.home"), "Library/Caches/scvpn-android")
    allprojects {
        layout.buildDirectory.set(File(outside, project.name))
    }
}
