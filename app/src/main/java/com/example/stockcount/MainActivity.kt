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
        scope.launch {
            val list = dao.allOnce()
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
    var menuOpen by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    var showAbout by remember { mutableStateOf(false) }
    // Item being added/edited. id = 0 means a new item.
    // Quantities typed on the cards but not saved yet (item id -> text).
    val drafts = remember { mutableStateMapOf<Long, String>() }
    var deleting by remember { mutableStateOf<Item?>(null) }
    val focusManager = LocalFocusManager.current
    fun saveAll() {
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
    var scanning by remember { mutableStateOf(false) }
    // Barcode that was scanned but is not in the material list.
    var notFound by remember { mutableStateOf<String?>(null) }

    fun handleScan(code: String) {
        scope.launch {
            // Same barcode on the current shelf -> +1.
            val found = dao.byBarcode(code, shelf.trim())
            if (found != null) {
                dao.change(found.id, 1)
                notify("✓ ${found.label()}  →  ${found.quantity + 1} ${found.uom}")
                return@launch
            }
            // Barcode is in the material list -> add it to this shelf with quantity 1, no typing needed.
            val m = materials.byBarcode(code)
            if (m != null) {
                val item = Item(
                    name = m.description, barcode = code, material = m.material, uom = m.uom,
                    shelf = shelf.trim(), stockType = stockType.trim(), storageLoc = storageLoc.trim(), quantity = 1
                )
                dao.save(item)
                notify("✓ Added ${item.label()}  →  1 ${item.uom}")
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
                        Text("Stock Count", fontWeight = FontWeight.SemiBold)
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
                            Text(if (drafts.isEmpty()) "Save" else "Save (${drafts.size})", fontWeight = FontWeight.SemiBold)
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
        LazyColumn(
            Modifier.padding(padding).fillMaxSize(),
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

            // ---- Shelf + search ----
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
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
                        modifier = Modifier.weight(1f)
                    )
                    OutlinedTextField(
                        value = search,
                        onValueChange = { search = it },
                        placeholder = { Text("Search") },
                        leadingIcon = { Icon(Icons.Filled.Search, null) },
                        singleLine = true,
                        shape = MaterialTheme.shapes.medium,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                        ),
                        modifier = Modifier.weight(1.2f)
                    )
                }
            }

            // ---- Totals ----
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    StatTile("Items", shown.size.toString(), Modifier.weight(1f))
                    StatTile("Units", shown.sumOf { it.quantity }.toString(), Modifier.weight(1f))
                    StatTile("Zero count", shown.count { it.zeroCount }.toString(), Modifier.weight(1f))
                }
            }

            if (items.isEmpty()) {
                item { EmptyState() }
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

    notFound?.let { code ->
        key(code) {
            EditDialog(
                item = Item(
                    name = "", barcode = code, shelf = shelf.trim(), stockType = stockType.trim(),
                    storageLoc = storageLoc.trim(), quantity = 1
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
fun EmptyState() {
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
        Text("No items counted yet", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(4.dp))
        Text(
            "Tap Scan to start counting.\nUpload your material list first.",
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
    var qty by remember { mutableStateOf(item.quantity.toString()) }
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
                enabled = material.isNotBlank() || name.isNotBlank(),
                onClick = {
                    onSave(item.copy(name = name.trim(), barcode = barcode.trim(), material = material.trim(), shelf = shelf.trim(), uom = uom.trim().ifEmpty { "EA" }, stockType = stockType.trim(), storageLoc = storageLoc.trim(), quantity = qty.toIntOrNull() ?: 0, zeroCount = zeroCount))
                }
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}
