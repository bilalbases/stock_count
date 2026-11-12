package com.example.stockcount

import android.Manifest
import android.content.BroadcastReceiver
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import android.os.Bundle
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

const val COPYRIGHT_YEAR = 2026

class MainActivity : ComponentActivity() {
    /** Barcodes from the Zebra hardware scanner, handed to the screen. */
    private val hardwareScans = MutableSharedFlow<String>(extraBufferCapacity = 16)
    private var zebraReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        ZebraScanner.configure(this)
        val db = AppDb.get(this)
        val settings = Settings(this)
        ThemeMode.mode = settings.theme
        setContent {
            StockTheme { StockScreen(db.items(), db.materials(), settings, hardwareScans) }
        }
    }

    override fun onResume() {
        super.onResume()
        zebraReceiver = ZebraScanner.register(this) { hardwareScans.tryEmit(it) }
    }

    override fun onPause() {
        zebraReceiver?.let { ZebraScanner.unregister(this, it) }
        zebraReceiver = null
        super.onPause()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StockScreen(dao: ItemDao, materials: MaterialDao, settings: Settings, hardwareScans: Flow<String>) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val itemsFlow = remember { dao.all() }
    val items by itemsFlow.collectAsStateWithLifecycle(initialValue = emptyList())
    val materialCountFlow = remember { materials.count() }
    val materialCount by materialCountFlow.collectAsStateWithLifecycle(initialValue = 0)
    val snackbar = remember { SnackbarHostState() }
    fun notify(msg: String) { scope.launch { snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(msg) } }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val msg = try {
                val result = withContext(Dispatchers.IO) { MaterialImport.read(context, uri) }
                if (result.materials.isEmpty()) {
                    "No materials found. The file needs MATERIAL, BARCODE and UOM columns."
                } else {
                    materials.replaceAll(result.materials)
                    "Imported ${result.materials.size} barcodes" +
                        if (result.skipped > 0) " (${result.skipped} rows skipped, missing material or barcode)" else ""
                }
            } catch (e: Exception) {
                "Import failed: ${e.message}"
            }
            notify(msg)
        }
    }
    fun importMaterials() = importLauncher.launch(
        arrayOf(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "text/csv", "text/comma-separated-values", "text/plain", "application/octet-stream"
        )
    )
    var search by remember { mutableStateOf("") }
    var detailsOpen by remember { mutableStateOf(settings.branch.isBlank()) }
    var branch by remember { mutableStateOf(settings.branch) }
    var shelf by remember { mutableStateOf(settings.shelf) }
    var planDate by remember { mutableStateOf(settings.planDate) }
    var stockType by remember { mutableStateOf(settings.stockType) }
    var storageLoc by remember { mutableStateOf(settings.storageLoc) }
    fun doExport() {
        if (branch.isBlank() || planDate.isBlank()) {
            detailsOpen = true
            notify("Enter Branch ID and Plan date before exporting")
            return
        }
        scope.launch {
            val list = dao.allOnce()
            if (list.isEmpty()) { notify("Nothing counted yet, no file created"); return@launch }
            val result = withContext(Dispatchers.IO) { XlsxExport.export(context, branch.trim(), planDate.trim(), list) }
            snackbar.currentSnackbarData?.dismiss()
            val answer = snackbar.showSnackbar(
                message = when {
                    result.unchanged -> "No changes since last export · ${result.savedTo ?: result.file.name}"
                    result.savedTo != null -> "Saved to ${result.savedTo}"
                    else -> "Could not save to Downloads"
                },
                actionLabel = "Share",
                withDismissAction = true,
                duration = SnackbarDuration.Long
            )
            if (answer == SnackbarResult.ActionPerformed) XlsxExport.shareFile(context, result.file)
        }
    }
    // Android 9 and older need permission to write to Downloads.
    val storagePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { doExport() }
    fun exportExcel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) {
            storagePermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        } else {
            doExport()
        }
    }
    // ---- Google Sheet upload ----
    val cloud = remember { CloudUpload.Config(context) }
    var showCloud by remember { mutableStateOf(false) }
    var uploading by remember { mutableStateOf(false) }
    fun uploadToSheet() {
        if (!cloud.isSet) { showCloud = true; return }
        if (uploading) return
        uploading = true
        notify("Uploading to Google Sheet…")
        scope.launch {
            val msg = try {
                val list = dao.allOnce()
                val n = withContext(Dispatchers.IO) { CloudUpload.upload(cloud, planDate.trim(), branch.trim(), list) }
                "✓ Uploaded $n items to Google Sheet as ${cloud.device}"
            } catch (e: Exception) {
                "Upload failed: ${e.message ?: "no connection"}"
            }
            uploading = false
            notify(msg)
        }
    }

    // ---- Merge several PI export files (offline) ----
    val mergeLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                val res = withContext(Dispatchers.IO) { XlsxExport.merge(context, uris) }
                snackbar.currentSnackbarData?.dismiss()
                val answer = snackbar.showSnackbar(
                    message = "Merged ${res.files} files (${res.inputRows} rows → ${res.outputRows}). " +
                        (res.savedTo?.let { "Saved to $it" } ?: "Could not save to Downloads"),
                    actionLabel = "Share",
                    withDismissAction = true,
                    duration = SnackbarDuration.Long
                )
                if (answer == SnackbarResult.ActionPerformed) XlsxExport.shareFile(context, res.file)
            } catch (e: Exception) {
                notify("Merge failed: ${e.message}")
            }
        }
    }
    var menuOpen by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    var showAbout by remember { mutableStateOf(false) }
    // Item being added/edited. id = 0 means a new item.
    // Quantities typed on the cards but not saved yet (item id -> text).
    val drafts = remember { mutableStateMapOf<Long, String>() }
    var deleting by remember { mutableStateOf<Item?>(null) }
    val focusManager = LocalFocusManager.current
    var scanning by remember { mutableStateOf(false) }
    val pager = rememberPagerState(pageCount = { 2 })

    // The item just scanned, waiting for the counter to type its quantity (not saved yet).
    var current by remember { mutableStateOf<Item?>(null) }
    var currentQty by remember { mutableStateOf("") }
    var currentZero by remember { mutableStateOf(false) }
    // Same barcode already counted on this shelf (the new quantity is added to it).
    var currentExisting by remember { mutableStateOf<Item?>(null) }

    /** Saves the scanned item with the typed quantity. Returns false if no quantity was entered. */
    fun saveCurrent(): Boolean {
        val item = current ?: return true
        val q = currentQty.toIntOrNull()
        if (q == null && !currentZero) {
            notify("Enter the quantity for ${item.label()}")
            return false
        }
        val qty = q ?: 0
        val zero = currentZero && qty == 0
        val existing = currentExisting
        current = null; currentQty = ""; currentZero = false; currentExisting = null
        scope.launch {
            if (existing != null) {
                val total = existing.quantity + qty
                dao.save(existing.copy(quantity = total, zeroCount = zero && total == 0))
                notify("✓ ${item.label()}  +$qty  →  $total ${item.uom}")
            } else {
                dao.save(item.copy(quantity = qty, zeroCount = zero))
                notify("✓ Saved ${item.label()}  →  $qty ${item.uom}")
            }
        }
        return true
    }
    fun saveAll() {
        // Save the scanned item first (if any); stop if its quantity is still empty.
        if (current != null) {
            if (!saveCurrent()) return
            if (drafts.isEmpty()) { focusManager.clearFocus(); return }
        }
        scope.launch {
            val current = dao.allOnce().associateBy { it.id }
            var changed = 0
            for ((id, text) in drafts.toMap()) {
                val item = current[id] ?: continue
                val q = text.toIntOrNull() ?: continue
                if (q != item.quantity) {
                    dao.save(item.copy(quantity = q, zeroCount = if (q > 0) false else item.zeroCount)); changed++
                }
            }
            drafts.clear()
            focusManager.clearFocus()
            notify(if (changed > 0) "Saved · $changed quantities updated" else "Saved")
        }
    }
    // Barcode that was scanned but is not in the material list.
    var notFound by remember { mutableStateOf<String?>(null) }

    fun handleScan(code: String) {
        scope.launch {
            // A previous scan is still waiting: keep it if a quantity was typed, otherwise drop it.
            if (current != null) {
                if (currentQty.isNotEmpty() || currentZero) saveCurrent()
                else { current = null; currentExisting = null }
            }
            val existing = dao.byBarcode(code, shelf.trim())
            val m = materials.byBarcode(code)
            if (existing != null || m != null) {
                // Show it on the Count page with an empty quantity box for the counter to fill in.
                current = existing?.copy() ?: Item(
                    name = m!!.description, barcode = code, material = m.material, uom = m.uom,
                    shelf = shelf.trim(), stockType = stockType.trim(), storageLoc = storageLoc.trim(), quantity = 0
                )
                currentExisting = existing
                currentQty = ""
                currentZero = false
                pager.animateScrollToPage(0)
                return@launch
            }
            // Unknown barcode -> open the item page so the barcode can be corrected or details typed in.
            notFound = code
        }
    }

    // Zebra trigger scans: count straight away (and close the camera view if it is open).
    LaunchedEffect(hardwareScans) {
        hardwareScans.collect { code ->
            scanning = false
            notFound = null
            handleScan(code)
        }
    }

    if (scanning) {
        BarcodeScanner(
            onResult = { code -> scanning = false; handleScan(code) },
            onClose = { scanning = false }
        )
        return
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Brand,
                    titleContentColor = Color.White,
                    actionIconContentColor = Color.White,
                ),
                title = {
                    Column {
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text("Stock Count", fontWeight = FontWeight.SemiBold)
                            Text(
                                " v${BuildConfig.VERSION_NAME}",
                                style = MaterialTheme.typography.labelMedium,
                                color = Color.White.copy(alpha = 0.75f),
                                modifier = Modifier.padding(start = 4.dp, bottom = 3.dp)
                            )
                        }
                        val sub = listOfNotNull(
                            branch.takeIf { it.isNotBlank() }?.let { "Branch $it" },
                            storageLoc.takeIf { it.isNotBlank() }?.let { "SLoc $it" },
                        ).joinToString(" · ")
                        if (sub.isNotEmpty()) {
                            Text(sub, style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.8f))
                        }
                    }
                },
                actions = {
                    IconButton(onClick = {
                        exportExcel()
                    }) { Icon(Icons.Filled.Share, contentDescription = "Export Excel") }
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = "More")
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("Upload material list") },
                            leadingIcon = { Icon(AppIcons.Upload, null) },
                            onClick = { menuOpen = false; importMaterials() }
                        )
                        DropdownMenuItem(
                            text = { Text("Export to Excel") },
                            leadingIcon = { Icon(Icons.Filled.Share, null) },
                            onClick = {
                                menuOpen = false
                                exportExcel()
                            }
                        )
                        DropdownMenuItem(
                            text = { Text("Upload to Google Sheet") },
                            onClick = { menuOpen = false; uploadToSheet() }
                        )
                        DropdownMenuItem(
                            text = { Text("Merge export files") },
                            onClick = {
                                menuOpen = false
                                mergeLauncher.launch(arrayOf(
                                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                    "application/octet-stream"
                                ))
                            }
                        )
                        DropdownMenuItem(
                            text = { Text("Cloud upload settings") },
                            onClick = { menuOpen = false; showCloud = true }
                        )
                        DropdownMenuItem(
                            text = { Text("Theme: ${ThemeMode.label}") },
                            onClick = {
                                ThemeMode.mode = ThemeMode.next()
                                settings.theme = ThemeMode.mode
                            }
                        )
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text("Start new count") },
                            onClick = { menuOpen = false; confirmClear = true }
                        )
                        DropdownMenuItem(
                            text = { Text("About") },
                            onClick = { menuOpen = false; showAbout = true }
                        )
                    }
                }
            )
        },
        bottomBar = {
            Column(Modifier.fillMaxWidth().navigationBarsPadding()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    ExtendedFloatingActionButton(
                        onClick = { saveAll() },
                        containerColor = MaterialTheme.colorScheme.secondary,
                        contentColor = MaterialTheme.colorScheme.onSecondary,
                        icon = { Icon(Icons.Filled.Check, contentDescription = null) },
                        text = {
                            val pending = drafts.size + (if (current != null) 1 else 0)
                            Text(if (pending == 0) "Save" else "Save ($pending)", fontWeight = FontWeight.SemiBold)
                        }
                    )
                    ExtendedFloatingActionButton(
                        onClick = { scanning = true },
                        containerColor = Brand,
                        contentColor = Color.White,
                        icon = { Icon(AppIcons.Barcode, contentDescription = null) },
                        text = { Text("Scan", fontWeight = FontWeight.SemiBold) }
                    )
                }
                Text(
                    "Powered by GGHL  ·  Developed by Bilal  ·  © $COPYRIGHT_YEAR Bilal",
                    style = MaterialTheme.typography.labelSmall,
                    color = FooterGrey,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                )
            }
        }
    ) { padding ->
        val shown = items.filter {
            search.isBlank() || it.name.contains(search, true) || it.barcode.contains(search) ||
                it.material.contains(search, true) || it.shelf.contains(search, true)
        }
        Column(Modifier.padding(padding).fillMaxSize()) {
            val counted = items.sortedBy { it.id }   // in the order they were counted
            TabRow(selectedTabIndex = pager.currentPage) {
                Tab(
                    selected = pager.currentPage == 0,
                    onClick = { scope.launch { pager.animateScrollToPage(0) } },
                    text = { Text("Count") }
                )
                Tab(
                    selected = pager.currentPage == 1,
                    onClick = { scope.launch { pager.animateScrollToPage(1) } },
                    text = { Text("Counted (${counted.size})") }
                )
            }
            HorizontalPager(state = pager, modifier = Modifier.weight(1f)) { page ->
                if (page == 0) {
                    // ================= Count page: details, shelf and the item just scanned =================
                    LazyColumn(
                        Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 24.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                    // ---- Count details (collapsible) ----
                    item {
                        ElevatedCard(
                            colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
                            shape = MaterialTheme.shapes.large
                        ) {
                            Row(
                                Modifier.fillMaxWidth().clickable { detailsOpen = !detailsOpen }.padding(16.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text("Count details", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                                    if (!detailsOpen) {
                                        val summary = listOf(
                                            "Branch ${branch.ifBlank { "–" }}",
                                            "Plan ${planDate.ifBlank { "today" }}",
                                            "SLoc ${storageLoc.ifBlank { "–" }}",
                                            "Type ${stockType.ifBlank { "–" }}",
                                        ).joinToString("  ·  ")
                                        Text(
                                            summary, style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 1, overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                }
                                Icon(
                                    if (detailsOpen) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                                    contentDescription = if (detailsOpen) "Hide" else "Show"
                                )
                            }
                            AnimatedVisibility(detailsOpen) {
                                Column(
                                    Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
                                    verticalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                        OutlinedTextField(
                                            value = branch,
                                            onValueChange = { branch = it; settings.branch = it },
                                            label = { Text("Branch ID (Plant)") },
                                            singleLine = true,
                                            modifier = Modifier.weight(1f)
                                        )
                                        OutlinedTextField(
                                            value = planDate,
                                            onValueChange = { v ->
                                                planDate = v.filter { it.isDigit() || it == '.' }.take(10); settings.planDate = planDate
                                            },
                                            label = { Text("Plan date") },
                                            placeholder = { Text("dd.mm.yyyy") },
                                            isError = planDate.isNotEmpty() && !XlsxExport.isValidDate(planDate),
                                            singleLine = true,
                                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                            modifier = Modifier.weight(1f)
                                        )
                                    }
                                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                        OutlinedTextField(
                                            value = storageLoc,
                                            onValueChange = { storageLoc = it.uppercase(); settings.storageLoc = storageLoc },
                                            label = { Text("Storage location") },
                                            singleLine = true,
                                            modifier = Modifier.weight(1f)
                                        )
                                        OutlinedTextField(
                                            value = stockType,
                                            onValueChange = { stockType = it.uppercase(); settings.stockType = stockType },
                                            label = { Text("Stock type") },
                                            singleLine = true,
                                            modifier = Modifier.weight(1f)
                                        )
                                    }
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(
                                            AppIcons.Inventory, null, Modifier.size(18.dp),
                                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Text(
                                            if (materialCount == 0) "No material list loaded" else "Material list: $materialCount barcodes",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = if (materialCount == 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                                            modifier = Modifier.weight(1f)
                                        )
                                        FilledTonalButton(onClick = { importMaterials() }, contentPadding = PaddingValues(horizontal = 12.dp)) {
                                            Icon(AppIcons.Upload, null, Modifier.size(18.dp))
                                            Spacer(Modifier.width(6.dp))
                                            Text("Upload materials")
                                        }
                                    }
                                }
                            }
                        }
                    }

                        item {
                            OutlinedTextField(
                                value = shelf,
                                onValueChange = { shelf = it; settings.shelf = it },
                                label = { Text("Current shelf") },
                                singleLine = true,
                                shape = MaterialTheme.shapes.medium,
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                                ),
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                        item {
                            val item = current
                            if (item == null) {
                                EmptyState(
                                    title = "Scan a barcode",
                                    text = if (counted.isEmpty()) "Tap Scan or press the scanner trigger.\nUpload your material list first."
                                    else "Tap Scan or press the scanner trigger.\nSwipe left to see the ${counted.size} counted items."
                                )
                            } else {
                                CurrentItemCard(
                                    item = item,
                                    alreadyCounted = currentExisting?.quantity,
                                    qty = currentQty,
                                    onQtyChange = { currentQty = it.filter(Char::isDigit).take(7); if (currentQty.isNotEmpty() && currentQty != "0") currentZero = false },
                                    zeroCount = currentZero,
                                    onZeroCount = { currentZero = it; if (it) currentQty = "0" },
                                    onSave = { if (saveCurrent()) focusManager.clearFocus() },
                                    onCancel = { current = null; currentExisting = null; currentQty = ""; currentZero = false; focusManager.clearFocus() }
                                )
                            }
                        }
                    }
                } else {
                    // ================= Counted page: everything saved so far =================
                    val shown = counted.filter {
                        search.isBlank() || it.name.contains(search, true) || it.barcode.contains(search) ||
                            it.material.contains(search, true) || it.shelf.contains(search, true)
                    }
                    LazyColumn(
                        Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 24.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        item {
                            OutlinedTextField(
                                value = search,
                                onValueChange = { search = it },
                                placeholder = { Text("Search counted items") },
                                leadingIcon = { Icon(Icons.Filled.Search, null) },
                                singleLine = true,
                                shape = MaterialTheme.shapes.medium,
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                                ),
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    // ---- Totals ----
                    item {
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            StatTile("Items", shown.size.toString(), Modifier.weight(1f))
                            StatTile("Units", shown.sumOf { it.quantity }.toString(), Modifier.weight(1f))
                            StatTile("Zero count", shown.count { it.zeroCount }.toString(), Modifier.weight(1f))
                        }
                    }

                        if (counted.isEmpty()) {
                            item { EmptyState(title = "Nothing counted yet", text = "Items appear here after you save their quantity.") }
                        }
                    items(shown, key = { it.id }) { item ->
                        fun step(delta: Int) {
                            val base = drafts[item.id]?.toIntOrNull() ?: item.quantity
                            drafts.remove(item.id)
                            val q = (base + delta).coerceAtLeast(0)
                            scope.launch { dao.save(item.copy(quantity = q, zeroCount = if (q > 0) false else item.zeroCount)) }
                        }
                        ItemCard(
                            item = item,
                            qtyText = drafts[item.id] ?: item.quantity.toString(),
                            onQtyChange = { drafts[item.id] = it.filter(Char::isDigit).take(7) },
                            onMinus = { step(-1) },
                            onPlus = { step(1) },
                            onZeroCount = { checked ->
                                drafts.remove(item.id)
                                scope.launch { dao.setZeroCount(item.id, checked) }
                            },
                            onDelete = { deleting = item },
                            onDone = { saveAll() }
                        )
                    }
                    }
                }
            }
        }
    }

    notFound?.let { code ->
        key(code) {
            EditDialog(
                item = Item(
                    name = "", barcode = code, shelf = shelf.trim(), stockType = stockType.trim(),
                    storageLoc = storageLoc.trim(), quantity = 0
                ),
                notFoundCode = code,
                lookup = { materials.byBarcode(it) },
                onDismiss = { notFound = null },
                onDelete = null,
                onSave = { newItem ->
                    notFound = null
                    scope.launch {
                        // If this barcode is already counted on this shelf, add to it instead of making a duplicate.
                        val existing = newItem.barcode.takeIf { it.isNotEmpty() }?.let { dao.byBarcode(it, newItem.shelf) }
                        if (existing != null) {
                            val q = existing.quantity + newItem.quantity
                            dao.save(existing.copy(quantity = q, zeroCount = if (q > 0) false else existing.zeroCount))
                            notify("✓ ${existing.label()}  →  $q ${existing.uom}")
                        } else {
                            dao.save(newItem)
                            notify("✓ Added ${newItem.label()}  →  ${newItem.quantity} ${newItem.uom}")
                        }
                    }
                }
            )
        }
    }

    if (showCloud) {
        var url by remember { mutableStateOf(cloud.url) }
        var key by remember { mutableStateOf(cloud.key) }
        var device by remember { mutableStateOf(cloud.device) }
        AlertDialog(
            onDismissRequest = { showCloud = false },
            title = { Text("Cloud upload settings") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        "Counts are sent to one Google Sheet so all PDTs end up in one file. " +
                            "Counting still works offline; only the upload needs Wi-Fi.",
                        style = MaterialTheme.typography.bodySmall
                    )
                    OutlinedTextField(url, { url = it.trim() }, label = { Text("Web app URL (…/exec)") }, singleLine = true)
                    OutlinedTextField(key, { key = it }, label = { Text("Key") }, singleLine = true)
                    OutlinedTextField(device, { device = it }, label = { Text("Device name") }, singleLine = true)
                }
            },
            confirmButton = {
                TextButton(
                    enabled = url.startsWith("https://") && key.isNotBlank() && device.isNotBlank(),
                    onClick = { cloud.url = url; cloud.key = key; cloud.device = device; showCloud = false; notify("Cloud upload settings saved") }
                ) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { showCloud = false }) { Text("Cancel") } }
        )
    }

    if (showAbout) {
        AlertDialog(
            onDismissRequest = { showAbout = false },
            icon = { Icon(AppIcons.Barcode, null, tint = Brand) },
            title = { Text("Stock Count") },
            text = {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Version ${BuildConfig.VERSION_NAME}")
                    Text("Powered by GGHL")
                    Text("Developed by Bilal")
                    Text("© $COPYRIGHT_YEAR Bilal. All rights reserved.")
                }
            },
            confirmButton = { TextButton(onClick = { showAbout = false }) { Text("OK") } }
        )
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Start a new count?") },
            text = { Text("This deletes all ${items.size} items. Export first if you need them.") },
            confirmButton = {
                TextButton(onClick = { scope.launch { dao.deleteAll() }; confirmClear = false }) {
                    Text("Delete all", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } }
        )
    }

    deleting?.let { item ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            icon = { Icon(Icons.Filled.Delete, null, tint = MaterialTheme.colorScheme.error) },
            title = { Text("Delete item?") },
            text = { Text("${item.label()} (${item.quantity} ${item.uom}) will be removed from this count.") },
            confirmButton = {
                TextButton(onClick = { drafts.remove(item.id); scope.launch { dao.delete(item) }; deleting = null }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } }
        )
    }
}

@Composable
fun StatTile(label: String, value: String, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.55f),
    ) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
            Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onPrimaryContainer)
            Text(label, style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.75f))
        }
    }
}

@Composable
fun EmptyState(title: String = "No items counted yet", text: String = "Tap Scan to start counting.") {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            Modifier.size(88.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center
        ) {
            Icon(AppIcons.Barcode, null, Modifier.size(44.dp), tint = MaterialTheme.colorScheme.primary)
        }
        Spacer(Modifier.height(16.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun Tag(text: String, strong: Boolean = false) {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        fontWeight = if (strong) FontWeight.SemiBold else FontWeight.Normal,
        color = if (strong) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(if (strong) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 6.dp, vertical = 2.dp)
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ItemCard(
    item: Item,
    qtyText: String,
    onQtyChange: (String) -> Unit,
    onMinus: () -> Unit,
    onPlus: () -> Unit,
    onZeroCount: (Boolean) -> Unit,
    onDelete: () -> Unit,
    onDone: () -> Unit,
) {
    ElevatedCard(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 1.dp)
    ) {
        Row(Modifier.fillMaxWidth().padding(start = 14.dp, end = 10.dp, top = 12.dp, bottom = 6.dp)) {
            Column(Modifier.weight(1f)) {
                Text(
                    item.label(), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                    maxLines = 2, overflow = TextOverflow.Ellipsis
                )
                val sub = listOfNotNull(
                    item.material.takeIf { it.isNotEmpty() && item.name.isNotEmpty() },
                    item.barcode.takeIf { it.isNotEmpty() }
                ).joinToString("  ·  ")
                if (sub.isNotEmpty()) {
                    Text(sub, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.height(6.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Tag(item.uom, strong = true)
                    if (item.shelf.isNotEmpty()) Tag("Shelf ${item.shelf}")
                    if (item.storageLoc.isNotEmpty()) Tag("SLoc ${item.storageLoc}")
                    if (item.stockType.isNotEmpty()) Tag("Type ${item.stockType}")
                }
            }
            Spacer(Modifier.width(8.dp))
            // Stepper
            Row(verticalAlignment = Alignment.CenterVertically) {
                StepButton("−", onMinus)
                // Tap the number to type a quantity; press Save (or Done on the keyboard) to keep it.
                val edited = qtyText != item.quantity.toString()
                BasicTextField(
                    value = qtyText,
                    onValueChange = onQtyChange,
                    singleLine = true,
                    textStyle = LocalTextStyle.current.copy(
                        fontSize = 22.sp,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center,
                        color = when {
                            edited -> MaterialTheme.colorScheme.secondary
                            item.zeroCount -> MaterialTheme.colorScheme.onSurfaceVariant
                            else -> MaterialTheme.colorScheme.onSurface
                        }
                    ),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.secondary),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { onDone() }),
                    modifier = Modifier.width(64.dp).padding(horizontal = 4.dp)
                )
                StepButton("+", onPlus, primary = true)
            }
        }
        Row(
            Modifier.fillMaxWidth().clickable { onZeroCount(!item.zeroCount) }.padding(start = 4.dp, end = 14.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Checkbox(checked = item.zeroCount, onCheckedChange = onZeroCount)
            Text(
                "Zero count",
                style = MaterialTheme.typography.bodyMedium,
                color = if (item.zeroCount) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                fontWeight = if (item.zeroCount) FontWeight.SemiBold else FontWeight.Normal,
                modifier = Modifier.weight(1f)
            )
            TextButton(
                onClick = onDelete,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
            ) {
                Icon(Icons.Filled.Delete, null, Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text("Delete")
            }
        }
    }
}

@Composable
private fun StepButton(symbol: String, onClick: () -> Unit, primary: Boolean = false) {
    FilledIconButton(
        onClick = onClick,
        modifier = Modifier.size(42.dp),
        shape = CircleShape,
        colors = if (primary) IconButtonDefaults.filledIconButtonColors(containerColor = Brand, contentColor = Color.White)
        else IconButtonDefaults.filledIconButtonColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant,
            contentColor = MaterialTheme.colorScheme.onSurface
        )
    ) { Text(symbol, fontSize = 22.sp, fontWeight = FontWeight.Medium) }
}

@Composable
fun EditDialog(
    item: Item,
    onDismiss: () -> Unit,
    onSave: (Item) -> Unit,
    onDelete: (() -> Unit)?,
    notFoundCode: String? = null,
    lookup: (suspend (String) -> Material?)? = null,
) {
    val scope = rememberCoroutineScope()
    var lookupMsg by remember { mutableStateOf<String?>(null) }
    var name by remember { mutableStateOf(item.name) }
    var barcode by remember { mutableStateOf(item.barcode) }
    var material by remember { mutableStateOf(item.material) }
    var shelf by remember { mutableStateOf(item.shelf) }
    var uom by remember { mutableStateOf(item.uom) }
    var stockType by remember { mutableStateOf(item.stockType) }
    var storageLoc by remember { mutableStateOf(item.storageLoc) }
    var qty by remember { mutableStateOf(if (notFoundCode != null) "" else item.quantity.toString()) }
    var zeroCount by remember { mutableStateOf(item.zeroCount) }
    var confirmDelete by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (notFoundCode != null) "Barcode not found" else if (item.id == 0L) "New item" else "Edit item") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (notFoundCode != null) {
                    Text(
                        "$notFoundCode is not in the material list. Correct the barcode (for example add a leading 0) and tap Look up, or fill in the details yourself.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error
                    )
                }
                OutlinedTextField(material, { material = it }, label = { Text("Material") }, singleLine = true)
                OutlinedTextField(name, { name = it }, label = { Text("Description (optional)") }, singleLine = true)
                OutlinedTextField(
                    barcode, { barcode = it.trim(); lookupMsg = null }, label = { Text("Barcode") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    trailingIcon = {
                        if (lookup != null) {
                            TextButton(onClick = { barcode = "0$barcode"; lookupMsg = null }) { Text("+0") }
                        }
                    }
                )
                if (lookup != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        FilledTonalButton(onClick = {
                            scope.launch {
                                val m = lookup(barcode)
                                if (m != null) {
                                    material = m.material
                                    uom = m.uom
                                    if (m.description.isNotBlank()) name = m.description
                                    lookupMsg = "✓ Found: ${m.material}"
                                } else {
                                    lookupMsg = "Still not found"
                                }
                            }
                        }) { Text("Look up") }
                        Spacer(Modifier.width(12.dp))
                        lookupMsg?.let {
                            Text(
                                it, style = MaterialTheme.typography.bodyMedium,
                                color = if (it.startsWith("✓")) MaterialTheme.colorScheme.secondary else MaterialTheme.colorScheme.error
                            )
                        }
                    }
                }
                OutlinedTextField(shelf, { shelf = it }, label = { Text("Shelf ID") }, singleLine = true)
                OutlinedTextField(storageLoc, { storageLoc = it.uppercase() }, label = { Text("Storage location") }, singleLine = true)
                OutlinedTextField(uom, { uom = it.uppercase() }, label = { Text("Unit (EA, CAR...)") }, singleLine = true)
                OutlinedTextField(stockType, { stockType = it.uppercase() }, label = { Text("Stock type") }, singleLine = true)
                OutlinedTextField(
                    qty, { qty = it.filter(Char::isDigit); if ((qty.toIntOrNull() ?: 0) > 0) zeroCount = false }, label = { Text("Quantity") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = zeroCount, onCheckedChange = { zeroCount = it; if (it) qty = "0" })
                    Text("Zero count")
                }
                if (onDelete != null) {
                    TextButton(onClick = { if (confirmDelete) onDelete() else confirmDelete = true }) {
                        Text(if (confirmDelete) "Tap again to delete" else "Delete item", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = (material.isNotBlank() || name.isNotBlank()) && (qty.isNotEmpty() || zeroCount),
                onClick = {
                    onSave(item.copy(name = name.trim(), barcode = barcode.trim(), material = material.trim(), shelf = shelf.trim(), uom = uom.trim().ifEmpty { "EA" }, stockType = stockType.trim(), storageLoc = storageLoc.trim(), quantity = qty.toIntOrNull() ?: 0, zeroCount = zeroCount))
                }
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}

/** The item just scanned: big empty quantity box for the counter to fill in, then Save. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CurrentItemCard(
    item: Item,
    alreadyCounted: Int?,
    qty: String,
    onQtyChange: (String) -> Unit,
    zeroCount: Boolean,
    onZeroCount: (Boolean) -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(item.barcode, item.shelf) { runCatching { focus.requestFocus() } }

    ElevatedCard(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 3.dp)
    ) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Scanned", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            Text(item.label(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            val sub = listOfNotNull(
                item.material.takeIf { it.isNotEmpty() && item.name.isNotEmpty() },
                item.barcode.takeIf { it.isNotEmpty() }
            ).joinToString("  ·  ")
            if (sub.isNotEmpty()) {
                Text(sub, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Tag(item.uom, strong = true)
                if (item.shelf.isNotEmpty()) Tag("Shelf ${item.shelf}")
                if (item.storageLoc.isNotEmpty()) Tag("SLoc ${item.storageLoc}")
                if (item.stockType.isNotEmpty()) Tag("Type ${item.stockType}")
            }
            if (alreadyCounted != null) {
                Text(
                    "Already counted on this shelf: $alreadyCounted ${item.uom}. The quantity you enter is added to it.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.secondary
                )
            }
            OutlinedTextField(
                value = qty,
                onValueChange = onQtyChange,
                label = { Text("Quantity (${item.uom})") },
                singleLine = true,
                textStyle = LocalTextStyle.current.copy(fontSize = 28.sp, fontWeight = FontWeight.Bold),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onSave() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus)
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = zeroCount, onCheckedChange = onZeroCount)
                Text("Zero count", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                TextButton(onClick = onCancel) { Text("Cancel") }
                Spacer(Modifier.width(4.dp))
                Button(
                    onClick = onSave,
                    enabled = qty.isNotEmpty() || zeroCount,
                    colors = ButtonDefaults.buttonColors(containerColor = Brand, contentColor = Color.White)
                ) { Text("Save") }
            }
        }
    }
}
