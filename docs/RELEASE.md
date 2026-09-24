# Release & distribution

Android-first release process for OfflineBoard. Commands are exact and
verified against the toolchain used for the sibling project (Flutter
3.47.5 stable, Temurin JDK 17, Android SDK 36 / build-tools 36.0.0, NDK
28.2.13676358 — required by `path_provider_android`'s dependency chain in
this environment).

> **Honesty note:** the release artifacts for *this* repo are built by the
> orchestrator after this documentation pass; the "Build verification
> log" section at the bottom is appended with the actual command outputs.
> iOS is scaffolded (`flutter create --platforms android,ios`) but NOT
  VERIFIED — see the iOS section.

## Versioning

`pubspec.yaml`: `version: 1.0.0+1` (semver + build number). Bump before a
release; the build number is what Android/Play treats as
`versionCode` (via Gradle's `flutter.versionCode`).

## Android — universal APK (REQUIRED main artifact)

Build one APK containing **all three ABIs** — this is the required
universal artifact for this project (NOT arm64-only, NOT
`--split-per-abi` for the main artifact):

```bash
flutter build apk --release --target-platform android-arm,android-arm64,android-x64
# → build/app/outputs/flutter-apk/app-release.apk
```

Why universal: a single file installs on any device (arm v7, arm64,
x64 emulators/Chromebooks) — right for a portfolio deliverable that
reviewers sideload. `--split-per-abi` would produce smaller per-ABI
files (`app-armeabi-v7a-release.apk`, `app-arm64-v8a-release.apk`,
`app-x86_64-release.apk`) but none of them alone installs everywhere.

Verify the ABIs actually shipped:

```bash
unzip -l build/app/outputs/flutter-apk/app-release.apk | grep lib/
# expect:
#   lib/armeabi-v7a/libflutter.so
#   lib/armeabi-v7a/libapp.so
#   lib/arm64-v8a/libflutter.so
#   lib/arm64-v8a/libapp.so
#   lib/x86_64/libflutter.so
#   lib/x86_64/libapp.so
```

## Android — App Bundle (Play Store upload format)

```bash
flutter build appbundle --release
# → build/app/build/app/outputs/bundle/release/app-release.aab
```

The AAB lets Play perform device-specific split APKs and dynamic
delivery. Inspect with `bundletool` if needed:

```bash
java -jar bundletool.jar build-apks --bundle=app-release.aab --output=ob.apks --mode=universal
```

## Signing reality (this environment)

- **Release artifacts in this sandbox are debug-signed.** Flutter's
  release builds for Android are signed with the debug keystore when no
  upload key is configured — fine for sideloading and portfolio
  distribution, NOT uploadable to Play.
- Check what an artifact is signed with:

  ```bash
  # APK
  keytool -printcert -jarfile build/app/outputs/flutter-apk/app-release.apk
  # AAB
  jarsigner -verify -verbose -certs app-release.aab | head
  ```

### Configuring a real keystore for Play Store

1. Generate (or import) a private upload key:

   ```bash
   keytool -genkey -v -keystore ~/upload-keystore.jks \
     -keyalg RSA -keysize 2048 -validity 10000 \
     -alias upload
   ```

2. Reference it from `android/key.properties` (**never commit this
   file** — add it to `.gitignore`):

   ```properties
   storePassword=<password>
   keyPassword=<password>
   keyAlias=upload
   storeFile=/absolute/path/to/upload-keystore.jks
   ```

3. Wire it into `android/app/build.gradle.kts` (read
   `key.properties` if present, else fall back to the debug key so CI and
   local dev keep working):

   ```kotlin
   import java.util.Properties
   import java.io.FileInputStream

   val keystoreProperties = Properties()
   val keystorePropertiesFile = rootProject.file("key.properties")
   if (keystorePropertiesFile.exists()) {
       keystoreProperties.load(FileInputStream(keystorePropertiesFile))
   }

   android {
       signingConfigs {
           create("release") {
               keyAlias = keystoreProperties["keyAlias"] as String
               keyPassword = keystoreProperties["keyPassword"] as String
               storeFile = file(keystoreProperties["storeFile"] as String)
               storePassword = keystoreProperties["storePassword"] as String
           }
       }
       buildTypes {
           release {
               signingConfig = signingConfigs.getByName("release")
           }
       }
   }
   ```

4. Play App Signing: enroll once in Play Console (Google manages the app
   signing key; your upload key is only used to sign uploads).

**Secrets discipline** (already the repo's practice): keystore files,
`key.properties` and any `*.jks` are gitignored; only test fixtures may
contain token-like strings; never commit a real credential.

## Pre-release checklist

```bash
dart format --output=none --set-exit-if-changed .   # format gate (CI enforces)
flutter analyze                                     # 0 issues
flutter test                                        # full suite green
flutter build apk --release --target-platform android-arm,android-arm64,android-x64
unzip -l build/app/outputs/flutter-apk/app-release.apk | grep lib/   # 3 ABIs present
flutter build appbundle --release
git status                                          # clean tree, no secrets
```

Artifacts live under `build/` (gitignored) — copy the ones worth keeping
to a stable location outside the repo (e.g. `~/offlineboard-artifacts/`)
before a `flutter clean`.

## iOS — scaffolded, NOT VERIFIED

- The `ios/` runner exists (`flutter create --platforms android,ios`),
  the Dart code is platform-clean, and nothing in the dependency graph
  prevents an iOS build.
- **However:** building and (especially) signing iOS requires macOS with
  Xcode + Apple developer certificates — neither is available in this
  Linux environment. No claim of a verified iOS artifact is made.

To release on iOS from a Mac:

```bash
flutter build ipa --release        # requires Xcode + signing identity
# then upload via Transporter / xcrun altool / App Store Connect
```

## Build verification log

<!-- The orchestrator appends the actual commands + outputs of the release
     builds below after they run (universal APK + AAB + ABI check). -->
