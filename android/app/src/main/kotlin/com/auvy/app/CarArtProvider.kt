package com.auvy.app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Gives Android Auto the library's own collection tiles (the shattered heart of
 * Liked Songs, the 50 of My Top 50, …) in the user's accent colour, so the car's
 * grids look like the app instead of a row of album covers.
 *
 * The tiles are Flutter assets, which the car can't open: it loads art only from
 * a content:// or android.resource:// address. Copying them into res/ would ship
 * every tile twice, so this serves `content://com.auvy.app.carart/<name>_<colour>`
 * from the assets instead. Only the names in [TILE] are served, read-only; they
 * are images every copy of the app carries, never anything of the user's.
 *
 * Each answer is a whole file, not a slice of the APK: some image loaders open a
 * content address with openFileDescriptor, which refuses a slice ("Not a whole
 * file"). The copy is unlinked once opened, so nothing accumulates in the cache.
 */
class CarArtProvider : ContentProvider() {

    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read-only")
        val name = uri.pathSegments.singleOrNull()
        if (name == null || !TILE.matches(name)) throw FileNotFoundException(uri.toString())
        val ctx = context ?: throw FileNotFoundException(uri.toString())
        try {
            val copy = File.createTempFile(name, ".webp", ctx.cacheDir)
            try {
                ctx.assets.open("flutter_assets/assets/images/$name.webp").use { input ->
                    copy.outputStream().use { input.copyTo(it) }
                }
                return ParcelFileDescriptor.open(copy, ParcelFileDescriptor.MODE_READ_ONLY)
            } finally {
                copy.delete()
            }
        } catch (e: IOException) {
            // A full disk, say: the car shows its placeholder, as for any missing art.
            throw FileNotFoundException("$uri: ${e.message}")
        }
    }

    override fun getType(uri: Uri) = "image/webp"

    override fun query(uri: Uri, projection: Array<String>?, selection: String?,
                       selectionArgs: Array<String>?, sortOrder: String?): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun update(uri: Uri, values: ContentValues?, selection: String?,
                        selectionArgs: Array<String>?) = 0

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0

    private companion object {
        /** The library's tiles (assets/images), in each accent's colour. */
        val TILE = Regex("(liked_songs|top_50|weekly_discovery|download|cached|playlist)_(cyan|green|orange|pink|purple|red)")
    }
}
