package com.example.stockcount

import android.content.Context
import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "items", indices = [Index(value = ["barcode", "shelf"])])
data class Item(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    val barcode: String = "",
    val shelf: String = "",
    val quantity: Int = 0,
    /** Unit of measure for ENTRY_UOM, e.g. EA or CAR. */
    val uom: String = "EA",
    /** Checked = counted and confirmed there are none (not just "not counted yet"). */
    val zeroCount: Boolean = false,
)

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

@Database(entities = [Item::class], version = 1)
abstract class AppDb : RoomDatabase() {
    abstract fun items(): ItemDao

    companion object {
        @Volatile private var instance: AppDb? = null
        fun get(context: Context): AppDb = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context.applicationContext, AppDb::class.java, "stock.db")
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
    var planDate: String
        get() = prefs.getString("planDate", "") ?: ""
        set(v) = prefs.edit().putString("planDate", v).apply()
}
