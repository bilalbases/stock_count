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
)

@Dao
interface ItemDao {
    @Query("SELECT * FROM items ORDER BY shelf COLLATE NOCASE, name COLLATE NOCASE")
    fun all(): Flow<List<Item>>

    @Query("SELECT * FROM items ORDER BY shelf COLLATE NOCASE, name COLLATE NOCASE")
    suspend fun allOnce(): List<Item>

    @Query("SELECT * FROM items WHERE barcode = :code AND barcode != '' AND shelf = :shelf LIMIT 1")
    suspend fun byBarcode(code: String, shelf: String): Item?

    @Query("SELECT name FROM items WHERE barcode = :code AND barcode != '' LIMIT 1")
    suspend fun nameForBarcode(code: String): String?

    @Upsert
    suspend fun save(item: Item)

    @Delete
    suspend fun delete(item: Item)

    @Query("DELETE FROM items")
    suspend fun deleteAll()

    @Query("UPDATE items SET quantity = MAX(0, quantity + :delta) WHERE id = :id")
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
}
