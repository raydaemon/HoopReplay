import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val localProperties = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
val webEnv = Properties().apply {
    rootProject.file("../web/.env.local").takeIf { it.exists() }?.reader()?.use { reader ->
        reader.readLines().filter { it.isNotBlank() && !it.trimStart().startsWith("#") }.forEach { line ->
            val separator = line.indexOf('=')
            if (separator > 0) setProperty(line.substring(0, separator), line.substring(separator + 1))
        }
    }
}
fun syncProperty(name: String, webName: String) =
    providers.gradleProperty(name).orNull?.takeIf { it.isNotBlank() }
        ?: localProperties.getProperty(name)?.takeIf { it.isNotBlank() }
        ?: webEnv.getProperty(webName, "")
fun buildConfigString(value: String): String =
    value.trim().removeSurrounding("\"").replace("\\", "\\\\").replace("\"", "\\\"")
val supabaseUrl = syncProperty("HOOPREPLAY_SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_URL")
val supabaseAnonKey = syncProperty("HOOPREPLAY_SUPABASE_ANON_KEY", "NEXT_PUBLIC_SUPABASE_ANON_KEY")
val syncSpace = syncProperty("HOOPREPLAY_SYNC_SPACE", "NEXT_PUBLIC_HOOPREPLAY_SYNC_SPACE")
val releaseStoreFile = providers.gradleProperty("HOOPREPLAY_RELEASE_STORE_FILE").orNull
    ?: localProperties.getProperty("HOOPREPLAY_RELEASE_STORE_FILE", "")
val releaseStorePassword = providers.gradleProperty("HOOPREPLAY_RELEASE_STORE_PASSWORD").orNull
    ?: localProperties.getProperty("HOOPREPLAY_RELEASE_STORE_PASSWORD", "")
val releaseKeyAlias = providers.gradleProperty("HOOPREPLAY_RELEASE_KEY_ALIAS").orNull
    ?: localProperties.getProperty("HOOPREPLAY_RELEASE_KEY_ALIAS", "")
val releaseKeyPassword = providers.gradleProperty("HOOPREPLAY_RELEASE_KEY_PASSWORD").orNull
    ?: localProperties.getProperty("HOOPREPLAY_RELEASE_KEY_PASSWORD", "")

android {
    namespace = "com.connectedai.hoopreplay"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.hoopreplay.android"
        minSdk = 29
        targetSdk = 36
        versionCode = 6102901
        versionName = "6.10.2901"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "SUPABASE_URL", "\"${buildConfigString(supabaseUrl)}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${buildConfigString(supabaseAnonKey)}\"")
        buildConfigField("String", "SYNC_SPACE", "\"${buildConfigString(syncSpace)}\"")
    }
    buildFeatures { compose = true; buildConfig = true }
    // The interface-language catalog is shared with the Web app: web/i18n/<code>.json becomes assets/i18n/<code>.json.
    sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/i18n"))
    val hasReleaseSigning = releaseStoreFile.isNotBlank() && releaseStorePassword.isNotBlank() &&
        releaseKeyAlias.isNotBlank() && releaseKeyPassword.isNotBlank()
    signingConfigs {
        if (hasReleaseSigning) {
            create("releaseUpload") {
                storeFile = file(releaseStoreFile)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        debug {
            // Debug must be installable over the production APK on physical devices.
            // It therefore always uses the same release-upload signing identity.
            check(hasReleaseSigning) {
                "Release signing is required for debug builds. Configure HOOPREPLAY_RELEASE_STORE_FILE, " +
                    "HOOPREPLAY_RELEASE_STORE_PASSWORD, HOOPREPLAY_RELEASE_KEY_ALIAS, and " +
                    "HOOPREPLAY_RELEASE_KEY_PASSWORD."
            }
            signingConfig = signingConfigs.getByName("releaseUpload")
        }
        release {
            check(hasReleaseSigning) { "Release signing credentials are required for release builds." }
            signingConfig = signingConfigs.getByName("releaseUpload")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_21)
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.09.00"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-video:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("androidx.camera:camera-effects:1.4.2")
    implementation("androidx.media3:media3-transformer:1.5.1")
    implementation("androidx.media3:media3-common:1.5.1")
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")

    androidTestImplementation(platform("androidx.compose:compose-bom:2024.09.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

val syncI18nCatalog by tasks.registering(Copy::class) {
    from(rootProject.file("../web/i18n")) { include("*.json") }
    into(layout.buildDirectory.dir("generated/i18n/i18n"))
}
tasks.named("preBuild") { dependsOn(syncI18nCatalog) }
