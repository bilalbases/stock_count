package com.example.stockcount

import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
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
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dao = AppDb.get(this).items()
        val settings = Settings(this)
        setContent {
            MaterialTheme { StockScreen(dao, settings) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StockScreen(dao: ItemDao, settings: Settings) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val itemsFlow = remember { dao.all() }
    val items by itemsFlow.collectAsStateWithLifecycle(initialValue = emptyList())
    var search by remember { mutableStateOf("") }
    var branch by remember { mutableStateOf(settings.branch) }
    var shelf by remember { mutableStateOf(settings.shelf) }
    var planDate by remember { mutableStateOf(settings.planDate) }
    var menuOpen by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    // Item being added/edited. id = 0 means a new item.
    var editing by remember { mutableStateOf<Item?>(null) }
    var scanning by remember { mutableStateOf(false) }

    fun handleScan(code: String) {
        scope.launch {
            // Same barcode on the current shelf -> +1. Otherwise add it to this shelf.
            val found = dao.byBarcode(code, shelf.trim())
            if (found != null) {
                dao.change(found.id, 1)
                Toast.makeText(context, "${found.name}: ${found.quantity + 1}", Toast.LENGTH_SHORT).show()
            } else {
                val known = dao.anyWithBarcode(code)
                editing = Item(
                    name = known?.name ?: "", barcode = code, shelf = shelf.trim(),
                    uom = known?.uom ?: "EA", quantity = 1
                )
            }
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
        topBar = {
            TopAppBar(
                title = { Text("Stock Count") },
                actions = {
                    IconButton(onClick = {
                        scope.launch { XlsxExport.share(context, branch.trim(), planDate.trim(), dao.allOnce()) }
                    }) { Icon(Icons.Filled.Share, contentDescription = "Export Excel") }
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = "More")
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("Start new count (delete all items)") },
                            onClick = { menuOpen = false; confirmClear = true }
                        )
                    }
                }
            )
        },
        floatingActionButton = {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SmallFloatingActionButton(onClick = { editing = Item(name = "", shelf = shelf.trim()) }) {
                    Icon(Icons.Filled.Add, contentDescription = "Add item")
                }
                ExtendedFloatingActionButton(onClick = { scanning = true }) { Text("Scan barcode") }
            }
        }
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = branch,
                    onValueChange = { branch = it; settings.branch = it },
                    label = { Text("Branch ID") },
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
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = shelf,
                    onValueChange = { shelf = it; settings.shelf = it },
                    label = { Text("Current shelf ID") },
                    singleLine = true,
                    modifier = Modifier.weight(1f)
                )
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    label = { Text("Search") },
                    singleLine = true,
                    modifier = Modifier.weight(1f)
                )
            }
            val shown = items.filter {
                search.isBlank() || it.name.contains(search, true) || it.barcode.contains(search) ||
                    it.shelf.contains(search, true)
            }
            Text(
                "${shown.size} items · ${shown.sumOf { it.quantity }} units",
                modifier = Modifier.padding(horizontal = 16.dp),
                style = MaterialTheme.typography.bodySmall
            )
            if (items.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("No items yet. Scan a barcode or tap + to add one.")
                }
            }
            LazyColumn(contentPadding = PaddingValues(bottom = 140.dp)) {
                items(shown, key = { it.id }) { item ->
                    ItemRow(
                        item = item,
                        onMinus = { scope.launch { dao.change(item.id, -1) } },
                        onPlus = { scope.launch { dao.change(item.id, 1) } },
                        onZeroCount = { checked -> scope.launch { dao.setZeroCount(item.id, checked) } },
                        onClick = { editing = item }
                    )
                    HorizontalDivider()
                }
            }
        }
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

    editing?.let { item ->
        EditDialog(
            item = item,
            onDismiss = { editing = null },
            onSave = { saved -> scope.launch { dao.save(saved) }; editing = null },
            onDelete = if (item.id != 0L) ({ scope.launch { dao.delete(item) }; editing = null }) else null
        )
    }
}

@Composable
fun ItemRow(item: Item, onMinus: () -> Unit, onPlus: () -> Unit, onZeroCount: (Boolean) -> Unit, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(item.name, fontWeight = FontWeight.Medium)
            val details = listOfNotNull(
                item.shelf.takeIf { it.isNotEmpty() }?.let { "Shelf $it" },
                item.barcode.takeIf { it.isNotEmpty() },
                item.uom
            ).joinToString(" · ")
            if (details.isNotEmpty()) Text(details, style = MaterialTheme.typography.bodySmall)
            Row(
                Modifier.clickable { onZeroCount(!item.zeroCount) },
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(checked = item.zeroCount, onCheckedChange = onZeroCount, modifier = Modifier.size(32.dp))
                Text("Zero count", style = MaterialTheme.typography.bodySmall)
            }
        }
        FilledTonalButton(onClick = onMinus, contentPadding = PaddingValues(0.dp), modifier = Modifier.size(44.dp)) {
            Text("−", fontSize = 22.sp)
        }
        Text(
            item.quantity.toString(),
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.widthIn(min = 56.dp).padding(horizontal = 8.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center
        )
        FilledTonalButton(onClick = onPlus, contentPadding = PaddingValues(0.dp), modifier = Modifier.size(44.dp)) {
            Text("+", fontSize = 22.sp)
        }
    }
}

@Composable
fun EditDialog(item: Item, onDismiss: () -> Unit, onSave: (Item) -> Unit, onDelete: (() -> Unit)?) {
    var name by remember { mutableStateOf(item.name) }
    var barcode by remember { mutableStateOf(item.barcode) }
    var shelf by remember { mutableStateOf(item.shelf) }
    var uom by remember { mutableStateOf(item.uom) }
    var qty by remember { mutableStateOf(item.quantity.toString()) }
    var zeroCount by remember { mutableStateOf(item.zeroCount) }
    var confirmDelete by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (item.id == 0L) "New item" else "Edit item") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
                OutlinedTextField(barcode, { barcode = it }, label = { Text("Barcode (optional)") }, singleLine = true)
                OutlinedTextField(shelf, { shelf = it }, label = { Text("Shelf ID") }, singleLine = true)
                OutlinedTextField(uom, { uom = it.uppercase() }, label = { Text("Unit (EA, CAR...)") }, singleLine = true)
                OutlinedTextField(
                    qty, { qty = it.filter(Char::isDigit); if ((qty.toIntOrNull() ?: 0) > 0) zeroCount = false }, label = { Text("Quantity") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = zeroCount, onCheckedChange = { zeroCount = it; if (it) qty = "0" })
                    Text("Zero count (checked, none on shelf)")
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
                enabled = name.isNotBlank(),
                onClick = {
                    onSave(item.copy(name = name.trim(), barcode = barcode.trim(), shelf = shelf.trim(), uom = uom.trim().ifEmpty { "EA" }, quantity = qty.toIntOrNull() ?: 0, zeroCount = zeroCount))
                }
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}
