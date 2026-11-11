# Take Your Pills

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

## Optional medicine catalog

Take Your Pills checks its private Android storage for the [Common Drug Codes for India Flat Files ZIP](https://www.nrces.in/resources) when opened or resumed and once a minute while in use. It builds a local SQLite index and refreshes it when the ZIP's SHA-256 changes. In **Add medicine**, type at least two characters for suggestions, or enter a name manually. **Settings → Medicine catalog** shows progress, the last successful index update, and the source licence.

On a debug emulator, copy the ZIP into private app storage from the project root. Use the same command to replace it with a newer file.

```sh
adb -e shell -T "run-as in.medisafe.medisafe sh -c 'mkdir -p files && cat > files/catalog.zip.next && mv files/catalog.zip.next files/CommonDrugCodesForIndia_FlatFilePackage.zip && wc -c < files/CommonDrugCodesForIndia_FlatFilePackage.zip'" \
  < data/CommonDrugCodesForIndia_FlatFilePackage.zip
```

For hosted updates, set `--dart-define=MEDISAFE_CATALOG_URL=https://example.com/catalog.zip` when building or running. The URL must serve the ZIP over HTTPS without sign-in. When configured, Take Your Pills checks on launch if the previous successful check was more than a day ago, then keeps checking while open. Failed downloads keep the current local catalog. The APK does not include the dataset.

## Set up Google Drive

1. Enable the Google Drive API in a Google Cloud project and set up its OAuth consent screen. Add test users if the app is in testing.
2. Create an Android OAuth client for `in.medisafe.medisafe` with the SHA-1 fingerprint of the certificate used to sign the app. Create a Web application OAuth client in the same project.
3. Pass the Web client ID when running or building the app.

```sh
flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_WEB_CLIENT_ID
```

On first launch, you can connect Google or choose **Not now**. You can connect later in **Settings → Google Drive**. After you connect, Take Your Pills checks for a backup and asks before restoring it. Use **Back up now** or set a preferred backup schedule. Android runs scheduled backups when background work and a network connection are available.

Take Your Pills uses the `drive.appdata` permission to store complete snapshots in its private Google Drive app folder. It keeps the newest backup, with a 5 MB limit per snapshot. During replacement, the previous backup is kept until the new one is saved. If a snapshot exceeds the limit, the existing backup and local data stay intact.

## iOS

Flutter screens, components, themes, models, and backup format are shared. The iOS project is scaffolded. It still needs a native notification implementation, iOS OAuth configuration, and platform verification before release.
