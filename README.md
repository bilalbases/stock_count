# Stock Count (Android)

A simple app for counting stock.

- **Branch ID** at the top: set once, saved, and written on every exported row.
- **Current shelf ID** at the top: new and scanned items go onto this shelf.
- **Scan barcode**: if the barcode is already on the current shelf, its count goes up by 1.
  Otherwise a "New item" box opens with the barcode and shelf filled in (and the name, if
  that barcode was seen on another shelf).
- **+ / −** buttons on each row, and a **Zero count** checkbox to confirm an item was checked and there are none (sets quantity to 0; pressing + clears it); tap a row to edit name, barcode, shelf, quantity, or delete it.
- **Share icon** exports an Excel file (.xlsx) in the PI template layout: DATE (today), PLAN_DATE (Plan date field), GJAHR (current year), PLANT (branch), STGE_LOC (shelf), ITEM, MATERIAL (barcode), STOCK_TYPE, ENTRY_QNT, ENTRY_UOM, ZERO_COUNT (X).
- **⋮ > Start new count** deletes all items.
- Works fully offline. Everything is saved on the phone (Room database), and the
  barcode model (ML Kit, bundled) is inside the APK. Scanning uses the camera through
  CameraX, so the app asks for camera permission on the first scan.

## Build

- **Android Studio:** File > Open this folder, then Run. Android Studio fills in the SDK.
- **Command line:** `./gradlew assembleDebug` → `app/build/outputs/apk/debug/app-debug.apk`
  (needs the Android SDK, `ANDROID_HOME` set).
- **GitHub:** push this folder to a repo; the workflow in `.github/workflows/build.yml`
  builds the APK and attaches it to the run as `stock-count-apk`.

Min Android version: 7.0 (API 24).
