# HoopReplay

An Android app for recording basketball games with live box-score stats. See [docs/func_spec.md](docs/func_spec.md) for the functional spec.

## Download

- Website: [www.hoopreplay.com](https://www.hoopreplay.com)
- Android: [Google Play](https://play.google.com/store/apps/details?id=com.hoopreplay.android)
- iOS: [App Store](https://apps.apple.com/app/hoopreplay/id6811926080)

## Build

Open `android/` in Android Studio and run `app`, or run `gradle -p android :app:assembleDebug` with Gradle 8.13 installed.

Requires Android 10 / API 29 or later. The camera permission must be granted on first launch; if the microphone permission is denied, video still records without sound.

## iOS

The native SwiftUI project lives in `ios/`. With full Xcode and XcodeGen installed, run `scripts/build-ios.sh`; the output is `HoopReplay-ios.app` at the repository root. Run `scripts/build-all.sh` to build Android and then iOS.

## Web and Sync

The Next.js Web version lives in `web/`, deploys on Vercel, and stores cross-device sync snapshots in Supabase. See [web/README.md](web/README.md) for setup and database migration steps. Videos stay on the recording device; teams, players, games, scores, clock state, and stats sync between Android and the Web.

## Scripts and Tests

- `scripts/*.sh`: command orchestration for building, deploying, launching, and taking screenshots.
- `tests/*.py`: end-to-end tests that involve state management, concurrent logs, assertions, or cleanup logic.
- `web/scripts/*.mjs`: server-side maintenance tasks that reuse the Web project's Node.js SDKs.

Run the full Android NBA first-quarter scenario:

```bash
./tests/nba-final-2026-g1-q1.py [adb-device-serial]
```

Run the Web end-to-end tests:

```bash
./tests/web-test.py
```

Keep the local Web dev server running (restarts automatically if it exits unexpectedly):

```bash
./scripts/web-run.sh
```

Production mode requires running `npm run build` first:

```bash
WEB_MODE=start ./scripts/web-run.sh
```
