# Stock Count local server (Windows)

Collects the counts from all PDTs over the local network (no internet) and builds one
locked Excel file per branch and storage location in the PI template layout: `Output\Stock_Count_<year>_<branch>_<sloc>.xlsx` (e.g. Stock_Count_2026_1090_1001.xlsx). Next to it, `Output\Stock_Count_Log_<year>_<branch>.xlsx` lists every scan as its own line (in scan order, with device, shelf and scan time).

## Install (once)
1. Copy this folder to the server PC, e.g. `C:\StockCount`.
2. Right-click **Install.cmd** > **Run as administrator**. Enter the upload password
   (the same as the app's key). The installer opens port 8080 in the firewall and registers
   the server to start automatically with Windows, then opens http://localhost:8080.

## Use
- PDTs: menu > **Upload to server**. Uploading again replaces that PDT's rows.
- Any PC on the network: open **http://192.168.11.162:8080** to see who has uploaded and
  download the Excel files (they are also in the `Output` folder).
- New count: on that page, **Clear all counts** (password needed). Old uploads and files are
  moved to `data\archive`, nothing is deleted.
- Or simply delete all files in the `Output` folder: the next upload then archives every PDT's
  earlier upload first, so old branches, storage locations and dates do not come back.
- "Start new count" on a PDT does not remove anything from the server: its next upload is kept as
  a new count next to the earlier one (`data\devices\<PDT>~<time>.json`, shown as "earlier count"
  on the status page). Uploads of the same count still replace each other, so corrections are not
  counted twice.
- One PDT with old counts: **Remove one PDT's upload** on that page (password needed).
- Log: `server.log`. To remove: **Uninstall.cmd** as administrator.

## Keeps running by itself
The task has no time limit (Windows normally stops scheduled tasks after 3 days) and is checked
every 5 minutes: if the server is not running, it is started again. Re-run Install.cmd after
updating the files; your password in key.txt is kept.
