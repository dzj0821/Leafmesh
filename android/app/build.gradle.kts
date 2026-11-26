import java.util.Properties
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}
val signingPropertiesFile = System.getenv("LEAFMESH_ANDROID_SIGNING_PROPERTIES")?.let { file(it) }
    ?: File(System.getenv("USERPROFILE") ?: System.getProperty("user.home"), ".leafmesh/signing/android/release.properties")
val releaseProperties = Properties().apply {
    if (signingPropertiesFile.isFile) signingPropertiesFile.inputStream().use { load(it) }
}
val releaseStore = releaseProperties.getProperty("storeFile")?.let {
    File(it).let { path -> if (path.isAbsolute) path else File(signingPropertiesFile.parentFile, it) }
}
val hasReleaseSigning = releaseStore?.isFile == true
android {
    namespace = "app.leafmesh.leafmesh"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    defaultConfig {
        applicationId = "app.leafmesh.leafmesh"
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk { abiFilters += listOf("arm64-v8a") }
    }
    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseStore
                storeType = releaseProperties.getProperty("storeType", "PKCS12")
                storePassword = releaseProperties.getProperty("storePassword")
                keyAlias = releaseProperties.getProperty("keyAlias")
                keyPassword = releaseProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else null
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}
flutter { source = "../.." }
dependencies {
    implementation(files("libs/leafmeshbridge.aar"))
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("androidx.core:core-ktx:1.16.0")
}
tasks.register("checkSyncthingBridge") {
    doLast { check(file("libs/leafmeshbridge.aar").exists()) { "Run python tool/build_android.py --bridge before building the APK" } }
}
tasks.named("preBuild").configure { dependsOn("checkSyncthingBridge") }
tasks.register("checkReleaseSigning") {
    doLast {
        check(hasReleaseSigning) { "Release 签名缺失，请恢复原有密钥及 release.properties，或设置 LEAFMESH_ANDROID_SIGNING_PROPERTIES。" }
        val pin = rootProject.file("release-certificate.sha256")
        check(pin.isFile) { "缺少 Release 证书指纹，不能打包。" }
        val store = KeyStore.getInstance(releaseProperties.getProperty("storeType", "PKCS12"))
        releaseStore!!.inputStream().use { store.load(it, releaseProperties.getProperty("storePassword").toCharArray()) }
        val certificate = store.getCertificate(releaseProperties.getProperty("keyAlias"))
        check(certificate != null) { "密钥别名中没有证书。" }
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        check(fingerprint == pin.readText().trim().lowercase()) { "Release 签名与已锁定的证书不一致。" }
    }
}
tasks.matching { it.name == "preReleaseBuild" || it.name == "validateSigningRelease" }.configureEach {
    dependsOn("checkReleaseSigning")
}
