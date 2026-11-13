package com.example.stockcount

import android.content.Context
import androidx.room.*
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import java.math.BigDecimal
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "items", indices = [Index(value = ["barcode", "shelf"])])
data class Item(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    val barcode: String = "",
    /** Material number (from the imported material list, or typed in). */
    val material: String = "",
    val shelf: String = "",
    /** Counted quantity in [uom]; decimals allowed (e.g. 1.25 KG for butchery and fresh). */
    val quantity: Double = 0.0,
    /** Unit of measure for ENTRY_UOM, e.g. EA or CAR. */
    val uom: String = "EA",
    /** STOCK_TYPE in the export (blank = unrestricted). */
    val stockType: String = "",
    /** STGE_LOC in the export (storage location, separate from shelf ID). */
    val storageLoc: String = "",
    /** Checked = counted and confirmed there are none (not just "not counted yet"). */
    val zeroCount: Boolean = false,
    /** SAP base unit (e.g. EA) from the material list; blank = uom is already the base unit. */
    @ColumnInfo(defaultValue = "''") val baseUom: String = "",
    /** How many base units one [uom] holds (e.g. 1 OTR = 10 EA). */
    @ColumnInfo(defaultValue = "1") val factor: Double = 1.0,
    /** When this line was scanned (epoch millis); each scan is its own line. */
    @ColumnInfo(defaultValue = "0") val scannedAt: Long = 0,
) {
    /** Unit written to the export: always the base unit when it is known. */
    fun exportUom(): String = baseUom.ifBlank { uom }

    /** Quantity in the base unit, e.g. 3 OTR x 10 = 30 EA. */
    fun exportQty(): BigDecimal =
        if (baseUom.isBlank() || factor == 1.0) BigDecimal.valueOf(quantity).stripTrailingZeros()
        else BigDecimal.valueOf(quantity).multiply(BigDecimal.valueOf(factor)).stripTrailingZeros()

    /** "1 OTR = 10 EA" when the counted unit is not the base unit, else empty. */
    fun unitHint(): String =
        if (baseUom.isBlank() || baseUom.equals(uom, true)) ""
        else "1 $uom = ${BigDecimal.valueOf(factor).stripTrailingZeros().toPlainString()} $baseUom"

    /** What to show in the list: description if there is one, else material, else barcode. */
    fun label() = name.ifBlank { material }.ifBlank { barcode }
}

@Dao
interface ItemDao {
    @Query("SELECT * FROM items ORDER BY shelf COLLATE NOCASE, name COLLATE NOCASE")
    fun all(): Flow<List<Item>>

    @Query("SELECT * FROM items ORDER BY shelf COLLATE NOCASE, name COLLATE NOCASE")
    suspend fun allOnce(): List<Item>

    @Query("SELECT * FROM items WHERE barcode = :code AND barcode != '' AND shelf = :shelf LIMIT 1")
    suspend fun byBarcode(code: String, shelf: String): Item?

    /** Same barcode counted on another shelf, used to pre-fill name and unit. */
    @Query("SELECT * FROM items WHERE barcode = :code AND barcode != '' AND shelf = :shelf ORDER BY id")
    suspend fun linesFor(code: String, shelf: String): List<Item>

    @Query("SELECT * FROM items WHERE barcode = :code AND barcode != '' LIMIT 1")
    suspend fun anyWithBarcode(code: String): Item?

    @Upsert
    suspend fun save(item: Item)

    @Delete
    suspend fun delete(item: Item)

    @Query("UPDATE items SET zeroCount = :checked, quantity = CASE WHEN :checked THEN 0 ELSE quantity END WHERE id = :id")
    suspend fun setZeroCount(id: Long, checked: Boolean)

    @Query("DELETE FROM items")
    suspend fun deleteAll()

    @Query("UPDATE items SET quantity = MAX(0, quantity + :delta), zeroCount = CASE WHEN :delta > 0 THEN 0 ELSE zeroCount END WHERE id = :id")
    suspend fun change(id: Long, delta: Int)
}

/** One row of the imported material list. A material can have several barcodes (e.g. EA and CAR). */
@Entity(tableName = "materials")
data class Material(
    @PrimaryKey val barcode: String,
    val material: String,
    val uom: String,
    val description: String = "",
    /** SAP base unit (MARA-MEINS), e.g. EA. Blank in old lists = uom is the base unit. */
    @ColumnInfo(defaultValue = "''") val baseUom: String = "",
    /** Base units per [uom] (MARM UMREZ / UMREN), e.g. 10 for OTR. */
    @ColumnInfo(defaultValue = "1") val factor: Double = 1.0,
)

@Dao
abstract class MaterialDao {
    @Query("SELECT * FROM materials WHERE barcode = :code LIMIT 1")
    abstract suspend fun byBarcode(code: String): Material?

    @Query("SELECT COUNT(*) FROM materials")
    abstract fun count(): Flow<Int>

    @Query("DELETE FROM materials")
    abstract suspend fun deleteAll()

    @Upsert
    abstract suspend fun saveAll(list: List<Material>)

    /** Replaces the whole list with a freshly imported one. */
    @Transaction
    open suspend fun replaceAll(list: List<Material>) {
        deleteAll()
        saveAll(list)
    }
}

@Database(entities = [Item::class, Material::class], version = 7, exportSchema = false)
abstract class AppDb : RoomDatabase() {
    abstract fun items(): ItemDao
    abstract fun materials(): MaterialDao

    companion object {
        @Volatile private var instance: AppDb? = null

        /** Adds the scan timestamp; existing lines keep their counts. */
        private val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE items ADD COLUMN scannedAt INTEGER NOT NULL DEFAULT 0")
            }
        }

        /** Quantity becomes a decimal (REAL); counts are copied over unchanged. */
        private val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS `items_new` (`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `name` TEXT NOT NULL, `barcode` TEXT NOT NULL, `material` TEXT NOT NULL, `shelf` TEXT NOT NULL, `quantity` REAL NOT NULL, `uom` TEXT NOT NULL, `stockType` TEXT NOT NULL, `storageLoc` TEXT NOT NULL, `zeroCount` INTEGER NOT NULL, `baseUom` TEXT NOT NULL DEFAULT '', `factor` REAL NOT NULL DEFAULT 1)")
                db.execSQL("INSERT INTO items_new (id, name, barcode, material, shelf, quantity, uom, stockType, storageLoc, zeroCount, baseUom, factor) SELECT id, name, barcode, material, shelf, quantity, uom, stockType, storageLoc, zeroCount, baseUom, factor FROM items")
                db.execSQL("DROP TABLE items")
                db.execSQL("ALTER TABLE items_new RENAME TO items")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_items_barcode_shelf` ON `items` (`barcode`, `shelf`)")
            }
        }

        /** Adds base unit + conversion factor, keeping the counts and the material list. */
        private val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (t in listOf("items", "materials")) {
                    db.execSQL("ALTER TABLE $t ADD COLUMN baseUom TEXT NOT NULL DEFAULT ''")
                    db.execSQL("ALTER TABLE $t ADD COLUMN factor REAL NOT NULL DEFAULT 1")
                }
            }
        }
        fun get(context: Context): AppDb = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context.applicationContext, AppDb::class.java, "stock.db")
                .addMigrations(MIGRATION_4_5, MIGRATION_5_6, MIGRATION_6_7)
                .fallbackToDestructiveMigration()
                .build().also { instance = it }
        }
    }
}

/** Branch ID and current shelf, remembered between app launches. */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    var branch: String
        get() = prefs.getString("branch", "") ?: ""
        set(v) = prefs.edit().putString("branch", v).apply()
    var shelf: String
        get() = prefs.getString("shelf", "") ?: ""
        set(v) = prefs.edit().putString("shelf", v).apply()
    /** PLAN_DATE in dd.MM.yyyy. Empty until the user types one; export then uses today. */
    var storageLoc: String
        get() = prefs.getString("storageLoc", "") ?: ""
        set(v) = prefs.edit().putString("storageLoc", v).apply()
    var stockType: String
        get() = prefs.getString("stockType", "") ?: ""
        set(v) = prefs.edit().putString("stockType", v).apply()
    var planDate: String
        get() = prefs.getString("planDate", "") ?: ""
        set(v) = prefs.edit().putString("planDate", v).apply()
    /** "system", "light" or "dark" */
    var theme: String
        get() = prefs.getString("theme", "system") ?: "system"
        set(v) = prefs.edit().putString("theme", v).apply()
}

/** 1.0 -> "1", 1.250 -> "1.25" */
fun fmtQty(q: Double): String = BigDecimal.valueOf(q).stripTrailingZeros().toPlainString().let { if (it == "0.0") "0" else it }

/** Typed text -> number; accepts "1.5" and "1,5". */
fun parseQty(s: String): Double? = s.trim().replace(',', '.').toDoubleOrNull()

/** Keeps digits and one decimal point (comma becomes point), max 3 decimals. */
fun cleanQty(s: String): String {
    val t = s.replace(',', '.').filter { it.isDigit() || it == '.' }
    val i = t.indexOf('.')
    val clean = if (i < 0) t else t.substring(0, i + 1) + t.substring(i + 1).replace(".", "").take(3)
    return clean.take(10)
}

/** a + b without floating-point noise (0.1 + 0.2 = 0.3). */
fun addQty(a: Double, b: Double): Double = BigDecimal.valueOf(a).add(BigDecimal.valueOf(b)).toDouble()
