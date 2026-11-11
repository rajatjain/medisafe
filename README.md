# Medisafe

An Android-first Flutter app for medication reminders. The app works offline and does not require an account. Google sign-in is used only for Google Drive backup and restore.

## Run on Android

Install Flutter and the Android SDK, then connect an Android 8.0 (API 26) or newer device or start an emulator.

```sh
flutter pub get
flutter test
flutter run
```

Open **Settings → Reminders** to allow notifications and exact alarms, and to play the pill bottle sound. The device controls lock screen visibility and may defer alerts when it restricts background activity. On a phone, verify the initial alert, follow-ups, snooze, and Taken/Skip actions with the app closed, then check history.

The reminder sound uses a trimmed and level-adjusted recording of [Pill Bottle Shaking](https://freesound.org/people/bwarpus99/sounds/443860/) by bwarpus99 ([CC0](https://creativecommons.org/publicdomain/zero/1.0/)).

## Set up Google Drive

1. Enable the Google Drive API in a Google Cloud project and set up its OAuth consent screen. Add test users if the app is in testing.
2. Create an Android OAuth client for `in.medisafe.medisafe` with the SHA-1 fingerprint of the certificate used to sign the app. Create a Web application OAuth client in the same project.
3. Pass the Web client ID when running or building the app.

```sh
flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_WEB_CLIENT_ID
```

On first launch, you can connect Google or choose **Not now**. You can connect later in **Settings → Google Drive**. After you connect, Medisafe checks for a backup and asks before restoring it. Use **Back up now** or set a preferred backup schedule. Android runs scheduled backups when background work and a network connection are available.

Medisafe uses the `drive.appdata` permission to store complete snapshots in its private Google Drive app folder. It keeps the newest backup, with a 5 MB limit per snapshot. During replacement, the previous backup is kept until the new one is saved. If a snapshot exceeds the limit, the existing backup and local data stay intact.

## iOS

Flutter screens, components, themes, models, and backup format are shared. The iOS project is scaffolded. It still needs a native notification implementation, iOS OAuth configuration, and platform verification before release.
