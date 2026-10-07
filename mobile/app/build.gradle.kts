plugins {
	id("com.android.application")
	id("org.jetbrains.kotlin.plugin.compose")
}

// The shell's icon names (style/theme/Icons.qml) and the protocol catalogue
// are the same files the PC uses; they are copied into the app at build time.
abstract class ShellAssets : DefaultTask() {
	@get:InputFile
	abstract val icons: RegularFileProperty

	@get:InputFile
	abstract val allIcons: RegularFileProperty

	@get:InputFile
	abstract val protocol: RegularFileProperty

	@get:OutputDirectory
	abstract val output: DirectoryProperty

	@TaskAction
	fun run() {
		val out = output.get().asFile
		out.mkdirs()
		val entry = Regex("\"([a-z0-9_]+)\":\\s*\"([^\"]+)\"")
		// every Material Design glyph of the font, then the shell's own names on top
		val names = sortedMapOf<String, String>()
		for (source in listOf(allIcons, icons)) entry.findAll(source.get().asFile.readText()).forEach { names[it.groupValues[1]] = it.groupValues[2] }
		val glyphs = names.entries.joinToString(",\n") { "\"${it.key}\": \"${it.value}\"" }
		out.resolve("icons.json").writeText("{\n$glyphs\n}\n")
		protocol.get().asFile.copyTo(out.resolve("protocol.json"), overwrite = true)
	}
}

val shellRoot = rootProject.projectDir.parentFile
val shellAssets = tasks.register<ShellAssets>("shellAssets") {
	icons.set(shellRoot.resolve("style/theme/Icons.qml"))
	allIcons.set(layout.projectDirectory.file("icons-md.json"))
	protocol.set(shellRoot.resolve("mobile/protocol/protocol.json"))
}

androidComponents {
	onVariants { variant ->
		variant.sources.assets?.addGeneratedSourceDirectory(shellAssets, ShellAssets::output)
	}
}

android {
	namespace = "dev.pshell.app"
	compileSdk = 37

	defaultConfig {
		applicationId = "dev.pshell.app"
		minSdk = 30
		targetSdk = 36
		versionCode = 3
		versionName = "1.2"
	}

	buildTypes {
		release {
			isMinifyEnabled = false
			signingConfig = signingConfigs.getByName("debug")
		}
	}

	compileOptions {
		sourceCompatibility = JavaVersion.VERSION_17
		targetCompatibility = JavaVersion.VERSION_17
	}

	buildFeatures {
		compose = true
		buildConfig = true
	}

	packaging {
		resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
	}
}

dependencies {
	implementation(platform("androidx.compose:compose-bom:2026.09.00"))
	implementation("androidx.compose.ui:ui")
	implementation("androidx.compose.foundation:foundation")
	implementation("androidx.compose.material3:material3")
	implementation("androidx.compose.ui:ui-tooling-preview")
	implementation("androidx.activity:activity-compose:1.13.0")
	implementation("androidx.core:core-ktx:1.19.1")
	implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
	implementation("androidx.lifecycle:lifecycle-process:2.11.0")
	implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
	implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
	implementation("com.squareup.okhttp3:okhttp:5.5.0")
	implementation("io.coil-kt.coil3:coil-compose:3.6.3")
	implementation("io.coil-kt.coil3:coil-network-okhttp:3.6.3")
	implementation("io.coil-kt.coil3:coil-svg:3.6.3")
	implementation("com.journeyapps:zxing-android-embedded:4.3.0")
	implementation("androidx.glance:glance-appwidget:1.2.0")

	testImplementation("junit:junit:4.13.2")
}
