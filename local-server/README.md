# Stock Count local server (Windows)

Collects the counts from all PDTs over the local network (no internet) and builds one
locked Excel file per branch in the PI template layout: `Output\Stock_Count_<year>_<branch>.xlsx`.

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
- Log: `server.log`. To remove: **Uninstall.cmd** as administrator.
