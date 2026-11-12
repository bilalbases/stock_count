/**
 * Stock Count – Google Sheet collector
 * -------------------------------------
 * Every PDT uploads its counted items here. Each upload REPLACES that device's rows,
 * so edits and deletions on the PDT are reflected and nothing is counted twice.
 *
 * Setup (once):
 *  1. Create a Google Sheet. Extensions > Apps Script. Paste this file, Save.
 *  2. Change SECRET below to your own password (the PDTs need the same one).
 *  3. Deploy > New deployment > type "Web app":
 *       Execute as: Me      Who has access: Anyone
 *     Copy the Web app URL (ends with /exec).
 *  4. In the app on each PDT: ⋮ > Cloud upload settings > paste the URL and the SECRET.
 *
 * At the end of the count: reload the Sheet, then menu "Stock Count":
 *   1. "Build PI sheets"  -> one tab per branch ("PI 1090", "PI 1100", ...)
 *   2. "Save PI files"    -> one Excel file per branch in the Drive folder "Stock Count PI",
 *                            named Stock_Count_<year>_<branch>.xlsx, with download links. (Asks once for Drive permission.)
 */

const SECRET = 'change-me';          // <-- change this, and enter the same value in the app
const COUNTS = 'Counts';             // raw rows from all devices
const PI = 'PI';                     // tab name prefix: one "PI <branch>" tab per branch

const COUNT_HEADERS = ['DEVICE', 'UPLOADED_AT', 'PLAN_DATE', 'PLANT', 'STGE_LOC', 'SHELF',
  'MATERIAL', 'BARCODE', 'DESCRIPTION', 'STOCK_TYPE', 'ENTRY_QNT', 'ENTRY_UOM', 'ZERO_COUNT'];

function doPost(e) {
  try {
    const body = JSON.parse(e.postData.contents);
    if (body.key !== SECRET) return json({ ok: false, error: 'Wrong key' });
    const device = String(body.device || '').trim();
    if (!device) return json({ ok: false, error: 'Missing device name' });

    const lock = LockService.getScriptLock();
    lock.waitLock(30000);
    try {
      const sh = countsSheet();
      const width = COUNT_HEADERS.length;
      // Keep the other devices' rows, replace this device's rows with the new upload
      const last = sh.getLastRow();
      const others = last > 1
        ? sh.getRange(2, 1, last - 1, width).getValues().filter(r => String(r[0]) !== device)
        : [];
      const now = new Date();
      const rows = (body.rows || []).map(r => [
        device, now, r.planDate || '', r.plant || '', r.storageLoc || '', r.shelf || '',
        r.material || '', r.barcode || '', r.description || '', r.stockType || '',
        String(Number(r.quantity) || 0), r.uom || '', r.zeroCount ? 'X' : ''
      ]);
      const all = others.concat(rows);
      if (last > 1) sh.getRange(2, 1, last - 1, width).clearContent();
      if (all.length) sh.getRange(2, 1, all.length, width).setValues(all);
      return json({ ok: true, rows: rows.length });
    } finally {
      lock.releaseLock();
    }
  } catch (err) {
    return json({ ok: false, error: String(err) });
  }
}

/** Opening the URL in a browser shows a simple check. */
function doGet() {
  return json({ ok: true, message: 'Stock Count collector is running' });
}

function onOpen() {
  SpreadsheetApp.getUi().createMenu('Stock Count')
    .addItem('Build PI sheets (one per branch)', 'buildPiSheet')
    .addItem('Save PI files (one Excel per branch)', 'savePiFiles')
    .addItem('Clear all counts', 'clearCounts')
    .addToUi();
}

/** Merges all devices into the PI template, one tab per branch ("PI 1090", "PI 1100", ...):
 *  one row per storage location + material + stock type + unit, quantities added together. */
function buildPiSheet() {
  const ss = SpreadsheetApp.getActive();
  const sh = countsSheet();
  const last = sh.getLastRow();
  const data = last > 1 ? sh.getRange(2, 1, last - 1, COUNT_HEADERS.length).getDisplayValues() : [];

  const plants = new Map();   // plant -> { planDate, groups: Map }
  data.forEach(r => {
    const [, , plan, plant, sloc, , material, barcode, , stockType, qty, uom, zero] = r;
    const mat = material || barcode;
    const p = plants.get(plant) || { planDate: '', groups: new Map() };
    const key = [sloc, mat, stockType, uom].join('|');
    const g = p.groups.get(key) || { sloc, mat, stockType, uom, qty: 0, zero: false };
    g.qty += Number(qty) || 0;
    g.zero = g.zero || zero === 'X';
    p.groups.set(key, g);
    if (!p.planDate && plan) p.planDate = plan;
    plants.set(plant, p);
  });

  // Remove the PI tabs from the previous run
  ss.getSheets().filter(t => t.getName() === PI || t.getName().startsWith(PI + ' ')).forEach(t => ss.deleteSheet(t));

  const tz = Session.getScriptTimeZone();
  const today = Utilities.formatDate(new Date(), tz, 'dd.MM.yyyy');
  const year = Utilities.formatDate(new Date(), tz, 'yyyy');
  const summary = [];
  let first = null;
  [...plants.keys()].sort().forEach(plant => {
    const p = plants.get(plant);
    const out = [['DATE', 'PLAN_DATE', 'GJAHR', 'PLANT', 'STGE_LOC', 'ITEM', 'MATERIAL',
      'STOCK_TYPE', 'ENTRY_QNT', 'ENTRY_UOM', 'ZERO_COUNT']];
    let item = 0;
    [...p.groups.values()]
      .sort((a, b) => (a.sloc + '|' + a.mat).localeCompare(b.sloc + '|' + b.mat))
      .forEach(g => out.push([today, p.planDate || today, year, plant, g.sloc, String(++item), g.mat,
        g.stockType, String(g.qty), g.uom, (g.zero && g.qty === 0) ? 'X' : '']));
    const tab = ss.insertSheet(PI + ' ' + (plant || 'no branch'));
    const range = tab.getRange(1, 1, out.length, out[0].length);
    range.setNumberFormat('@');               // all text: materials keep every digit
    range.setValues(out);
    tab.getRange(1, 1, 1, out[0].length).setFontWeight('bold');
    tab.setFrozenRows(1);
    tab.autoResizeColumns(1, out[0].length);
    summary.push(`${tab.getName()}: ${out.length - 1} rows`);
    first = first || tab;
  });
  if (first) ss.setActiveSheet(first);
  SpreadsheetApp.getUi().alert(plants.size
    ? `Built one PI tab per branch from ${data.length} counted lines:\n\n${summary.join('\n')}\n\n` +
      'Next: menu Stock Count > Save PI files (one Excel per branch).'
    : 'No counts uploaded yet.');
}

/** Saves every "PI <branch>" tab as its own Excel file in the Drive folder "Stock Count PI". */
function savePiFiles() {
  const ss = SpreadsheetApp.getActive();
  const tabs = ss.getSheets().filter(t => t.getName().startsWith(PI + ' '));
  if (!tabs.length) { SpreadsheetApp.getUi().alert('Run Stock Count > Build PI sheets first.'); return; }
  const folders = DriveApp.getFoldersByName('Stock Count PI');
  const folder = folders.hasNext() ? folders.next() : DriveApp.createFolder('Stock Count PI');
  const year = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy');
  const links = tabs.map(tab => {
    const plant = tab.getName().substring(PI.length + 1);
    const temp = SpreadsheetApp.create('PI_' + plant);
    tab.copyTo(temp).setName('PI');
    temp.deleteSheet(temp.getSheets()[0]);
    SpreadsheetApp.flush();
    const blob = UrlFetchApp.fetch(
      'https://docs.google.com/spreadsheets/d/' + temp.getId() + '/export?format=xlsx',
      { headers: { Authorization: 'Bearer ' + ScriptApp.getOAuthToken() } }
    ).getBlob().setName(`Stock_Count_${year}_${plant}.xlsx`);   // e.g. Stock_Count_2026_1100.xlsx
    // Saving again replaces the branch's previous file instead of adding a duplicate
    const old = folder.getFilesByName(blob.getName());
    while (old.hasNext()) old.next().setTrashed(true);
    const file = folder.createFile(blob);
    DriveApp.getFileById(temp.getId()).setTrashed(true);
    return `<li><a href="https://drive.google.com/uc?export=download&id=${file.getId()}" target="_blank">${file.getName()}</a></li>`;
  });
  const html = HtmlService.createHtmlOutput(
    `<p style="font-family:sans-serif">Saved ${links.length} file(s) to the Drive folder <b>Stock Count PI</b>. Click to download:</p>` +
    `<ul style="font-family:sans-serif">${links.join('')}</ul>`).setWidth(460).setHeight(320);
  SpreadsheetApp.getUi().showModalDialog(html, 'PI files per branch');
}

function clearCounts() {
  const ui = SpreadsheetApp.getUi();
  if (ui.alert('Delete all uploaded counts?', ui.ButtonSet.YES_NO) !== ui.Button.YES) return;
  const sh = countsSheet();
  if (sh.getLastRow() > 1) sh.deleteRows(2, sh.getLastRow() - 1);
}

function countsSheet() {
  const ss = SpreadsheetApp.getActive();
  let sh = ss.getSheetByName(COUNTS);
  if (!sh) {
    sh = ss.insertSheet(COUNTS);
    sh.getRange(1, 1, 1, COUNT_HEADERS.length).setValues([COUNT_HEADERS]).setFontWeight('bold');
    sh.setFrozenRows(1);
    sh.getRange('C:M').setNumberFormat('@');  // keep codes as text
  }
  return sh;
}

function json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
