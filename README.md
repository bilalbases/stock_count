# Stock Count (Android)

A simple app for counting stock.

- **Branch ID** at the top: set once, saved, and written on every exported row.
- **Current shelf ID** at the top: new and scanned items go onto this shelf.
- **Upload materials** (under the header, or ⋮ > Import material list): pick an Excel (.xlsx) or CSV
  file with columns MATERIAL, BARCODE, UOM (optional DESCRIPTION). Header names are matched loosely
  (EAN, UNIT, MEINS, MAKTX also work); without a header, columns A-D are read in that order.
  Importing replaces the previous list. A material can appear on several rows with different barcodes
  (e.g. one for EA, one for CAR).
- **Scan barcode**: a barcode in the material list is added to the current shelf with its material
  and unit, no typing needed; if the barcode is already on the current shelf, its count goes up by 1.
  A barcode that is not in the material list adds nothing and shows a "Barcode not found"
  message with a "Scan again" button.
- Each item card has **− / +** buttons, a quantity you can tap and type into, a **Zero count**
  checkbox (sets quantity to 0; pressing + clears it) and a **Delete** button (asks first).
- **Save** (bottom left) stores typed quantities. − / +, zero count and scans are saved straight away.
  Items are only added by scanning; there is no manual add form.
- **Share icon** exports an Excel file (.xlsx) in the PI template layout: DATE (today), PLAN_DATE (Plan date field), GJAHR (current year), PLANT (branch), STGE_LOC (Storage location field, editable per item; shelf ID stays in the app only), ITEM, MATERIAL (from the material list), STOCK_TYPE (Stock type field, editable per item), ENTRY_QNT, ENTRY_UOM, ZERO_COUNT (X).
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

---
Powered by GGHL · Developed by Bilal · © 2026 Bilal. All rights reserved.
