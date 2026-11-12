package com.example.stockcount

import android.content.Context
import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "items", indices = [Index(value = ["barcode", "shelf"])])
data class Item(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    val barcode: String = "",
    /** Material number (from the imported material list, or typed in). */
    val material: String = "",
    val shelf: String = "",
    val quantity: Int = 0,
    /** Unit of measure for ENTRY_UOM, e.g. EA or CAR. */
    val uom: String = "EA",
    /** STOCK_TYPE in the export (blank = unrestricted). */
    val stockType: String = "",
    /** STGE_LOC in the export (storage location, separate from shelf ID). */
    val storageLoc: String = "",
    /** Checked = counted and confirmed there are none (not just "not counted yet"). */
    val zeroCount: Boolean = false,
) {
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

@Database(entities = [Item::class, Material::class], version = 4, exportSchema = false)
abstract class AppDb : RoomDatabase() {
    abstract fun items(): ItemDao
    abstract fun materials(): MaterialDao

    companion object {
        @Volatile private var instance: AppDb? = null
        fun get(context: Context): AppDb = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context.applicationContext, AppDb::class.java, "stock.db")
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
