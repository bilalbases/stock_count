# Stock Count (Android)

A simple app for counting stock.

- **Branch ID** at the top: set once, saved, and written on every exported row.
- **Current shelf ID** at the top: new and scanned items go onto this shelf.
- **Upload materials** (under the header, or ⋮ > Import material list): pick an Excel (.xlsx) or CSV
  file with columns MATERIAL, BARCODE, UOM (optional DESCRIPTION). Header names are matched loosely
  (EAN, UNIT, MEINS, MAKTX also work); without a header, columns A-D are read in that order.
  Importing replaces the previous list. A material can appear on several rows with different barcodes
  (e.g. one for EA, one for CAR).
- **Zebra devices:** the hardware scanner (trigger buttons) works too. On first start the app creates a
  DataWedge profile called "StockCount" that sends scans to the app (keystroke output off). A trigger
  scan counts the barcode immediately, the same as a camera scan. If it doesn't react, open DataWedge
  on the device and check that the StockCount profile is enabled and linked to com.example.stockcount.
- **Two pages:** *Count* (count details, current shelf, and the item just scanned) and *Counted*
  (everything saved so far, in the order it was counted). Swipe right-to-left or tap the tabs.
- **Scanning** shows the item on the Count page with an **empty quantity box**. Type the quantity and
  press Save (or Done on the keyboard); the item moves to the Counted page. Scanning a barcode that is
  already counted on the same shelf adds the new quantity to it. Scanning the next item while a
  quantity is typed saves the previous one automatically.
- **Scan barcode** (camera): a barcode in the material list is added to the current shelf with its material
  and unit, no typing needed; if the barcode is already on the current shelf, its count goes up by 1.
  A barcode that is not in the material list opens the item page ("Barcode not found"): correct the
  barcode (the +0 button adds a leading zero) and tap Look up to fill in material and unit from the
  list, or type the details yourself, then Save. Cancel adds nothing.
- Each item card has **− / +** buttons, a quantity you can tap and type into, a **Zero count**
  checkbox (sets quantity to 0; pressing + clears it) and a **Delete** button (asks first).
- **Save** (bottom left) stores typed quantities. − / +, zero count and scans are saved straight away.
  Items are only added by scanning; there is no manual add form.
- **Export icon** saves one Excel file (.xlsx) to Downloads/StockCount on the device. A message with a **Share** button appears if you want to send it (email, WhatsApp, Drive). If nothing changed since the last export, no new file is created; exporting again in the same minute replaces the file. The Save button never creates files. The file is in the PI template layout: DATE (today), PLAN_DATE (Plan date field), GJAHR (current year), PLANT (branch), STGE_LOC (Storage location field, editable per item; shelf ID stays in the app only), ITEM, MATERIAL (from the material list), STOCK_TYPE (Stock type field, editable per item), ENTRY_QNT, ENTRY_UOM, ZERO_COUNT (X). The exported file is locked (sheet and workbook protection with a random password) so it cannot be edited in Excel.
- **⋮ > Start new count** deletes all items.
- **Merging many PDTs into one file** (quantities of the same plant + storage location + material +
  stock type + unit are added into one row, ITEM is renumbered):
  - *Online, Google Sheet:* set up once with [google-sheet/Code.gs](google-sheet/Code.gs) (steps at the
    top of that file). On each PDT: ⋮ > Cloud upload settings (Web app URL, key, device name), then
    ⋮ > Upload to Google Sheet. Uploading again replaces that device's rows, so nothing is counted twice.
    In the Sheet: menu Stock Count > Build PI sheets (one tab per branch), then Save PI files
    (one Excel per branch in the Drive folder "Stock Count PI").
  - *Offline:* collect the exported files on one device (WhatsApp, email, USB), then ⋮ > Merge export
    files and select them all. The merged file `PI_MERGED_...xlsx` is saved to Downloads/StockCount.
- Works fully offline (only the optional Google Sheet upload needs internet). Everything is saved on the phone (Room database), and the
  barcode model (ML Kit, bundled) is inside the APK. Scanning uses the camera through
  CameraX, so the app asks for camera permission on the first scan.

## Build

- **Android Studio:** File > Open this folder, then Run. Android Studio fills in the SDK.
- **Command line:** `./gradlew assembleDebug` → `app/build/outputs/apk/debug/app-debug.apk`
  (needs the Android SDK, `ANDROID_HOME` set).
- **GitHub:** push this folder to a repo; the workflow in `.github/workflows/build.yml`
  builds the APK and publishes it as a release. Latest APK (no login needed):
  https://github.com/bilalbases/stock_count/releases/latest/download/stock-count.apk

Min Android version: 7.0 (API 24).

---
Powered by GGHL · Developed by Bilal · © 2026 Bilal. All rights reserved.
