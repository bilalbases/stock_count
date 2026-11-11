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
 * At the end of the count: reload the Sheet, menu "Stock Count" > "Build PI sheet".
 * Then File > Download > Microsoft Excel (.xlsx) while the "PI" tab is open
 * (or delete the other tabs from the downloaded copy).
 */

const SECRET = 'change-me';          // <-- change this, and enter the same value in the app
const COUNTS = 'Counts';             // raw rows from all devices
const PI = 'PI';                     // merged file in the PI template layout

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
    .addItem('Build PI sheet', 'buildPiSheet')
    .addItem('Clear all counts', 'clearCounts')
    .addToUi();
}

/** Merges all devices into the PI template: one row per plant + storage location + material + stock type + unit. */
function buildPiSheet() {
  const ss = SpreadsheetApp.getActive();
  const sh = countsSheet();
  const last = sh.getLastRow();
  const data = last > 1 ? sh.getRange(2, 1, last - 1, COUNT_HEADERS.length).getDisplayValues() : [];

  const groups = new Map();
  let planDate = '';
  data.forEach(r => {
    const [device, , plan, plant, sloc, , material, barcode, , stockType, qty, uom, zero] = r;
    const mat = material || barcode;
    const key = [plant, sloc, mat, stockType, uom].join('|');
    const g = groups.get(key) || { plant, sloc, mat, stockType, uom, qty: 0, zero: false };
    g.qty += Number(qty) || 0;
    g.zero = g.zero || zero === 'X';
    groups.set(key, g);
    if (!planDate && plan) planDate = plan;
  });

  const today = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'dd.MM.yyyy');
  const year = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy');
  const out = [['DATE', 'PLAN_DATE', 'GJAHR', 'PLANT', 'STGE_LOC', 'ITEM', 'MATERIAL',
    'STOCK_TYPE', 'ENTRY_QNT', 'ENTRY_UOM', 'ZERO_COUNT']];
  let item = 0;
  [...groups.values()]
    .sort((a, b) => (a.plant + a.sloc + a.mat).localeCompare(b.plant + b.sloc + b.mat))
    .forEach(g => out.push([today, planDate || today, year, g.plant, g.sloc, String(++item), g.mat,
      g.stockType, String(g.qty), g.uom, (g.zero && g.qty === 0) ? 'X' : '']));

  let pi = ss.getSheetByName(PI);
  if (pi) pi.clear(); else pi = ss.insertSheet(PI);
  const range = pi.getRange(1, 1, out.length, out[0].length);
  range.setNumberFormat('@');               // all text: barcodes/materials keep every digit
  range.setValues(out);
  pi.getRange(1, 1, 1, out[0].length).setFontWeight('bold');
  pi.setFrozenRows(1);
  pi.autoResizeColumns(1, out[0].length);
  ss.setActiveSheet(pi);
  SpreadsheetApp.getUi().alert(`PI sheet built: ${out.length - 1} rows from ${data.length} counted lines.\n\n` +
    'Download it with File > Download > Microsoft Excel (.xlsx).');
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
