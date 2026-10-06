package app.swiftdrop.swiftdrop

import android.app.Activity
import android.app.DownloadManager
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Where received files finally go. The Dart engine receives into private staging, checks
 * every block, then calls [publish] once per verified file; nothing incomplete is ever
 * visible to Gallery or the file manager.
 *
 *  - media  -> MediaStore (Pictures / Movies / Music), published with IS_PENDING so the
 *              Gallery only sees the finished file (API 29+); a public-folder write plus a
 *              media scan below that
 *  - files  -> Downloads/SwiftDrop (MediaStore.Downloads, API 29+; public folder below)
 *  - chosen -> a Storage Access Framework tree the person picked once (persisted grant)
 *
 * Bytes are streamed (FileChannel.transferTo or 1 MiB buffers): never loaded whole.
 */
class StorageBridge(private val activity: Activity) {
    private val io = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private val resolver get() = activity.contentResolver
    private var pendingPick: MethodChannel.Result? = null

    /** Folder document URIs by tree + relative path, so thousands of files don't re-list. */
    private val folders = ConcurrentHashMap<String, Uri>()

    class NoSpace(msg: String) : IOException(msg)

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "publish", "exists", "freeSpace" -> io.execute {
                try {
                    val out: Any? = when (call.method) {
                        "publish" -> publish(call)
                        "exists" -> exists(call)
                        else -> freeSpace()
                    }
                    main.post { result.success(out) }
                } catch (e: NoSpace) {
                    main.post { result.error("noSpace", e.message, null) }
                } catch (e: Exception) {
                    val full = e.message?.contains("ENOSPC") == true
                    main.post { result.error(if (full) "noSpace" else "write", e.message ?: e.toString(), null) }
                }
            }
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "pickFolder" -> pickFolder(result)
            "folderGranted" -> result.success(folderGranted(call.argument<String>("uri")))
            "releaseFolder" -> {
                releaseFolder(call.argument<String>("uri"))
                result.success(null)
            }
            "canOpen" -> result.success(canOpen(call.argument<String>("what"), call.argument<String>("uri")))
            "open" -> result.success(open(call.argument<String>("what"), call.argument<String>("uri")))
            else -> return false
        }
        return true
    }

    // ------------------------------------------------------------------ publish

    private fun publish(call: MethodCall): Map<String, Any?> {
        val src = File(call.argument<String>("path")!!)
        val name = call.argument<String>("name")!!
        val mime = call.argument<String>("mime")?.takeIf { it.isNotEmpty() } ?: guessMime(name)
        val kind = call.argument<String>("kind") ?: "file"
        val target = call.argument<String>("target") ?: "downloads"
        val relDir = safeSegments(call.argument<List<String>>("relDir"))
        val modified = (call.argument<Number>("lastModified") ?: 0).toLong()
        val replace = call.argument<Boolean>("replace") == true
        val tree = call.argument<String>("tree")
        if (!src.isFile) throw IOException("staged file missing")
        checkSpace(src.length())
        val k = if (target == "gallery") kind else "file"
        return when {
            target == "tree" && tree != null -> publishTree(src, Uri.parse(tree), relDir, name, mime, replace)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> publishMediaStore(src, k, relDir, name, mime, modified, replace)
            else -> publishLegacy(src, k, relDir, name, mime, modified, replace)
        }
    }

    private fun checkSpace(needed: Long) {
        val free = freeSpace()
        if (free in 0 until needed) throw NoSpace("not enough space")
    }

    private fun freeSpace(): Long = try {
        StatFs(Environment.getExternalStorageDirectory().path).availableBytes
    } catch (e: Exception) {
        -1L
    }

    private fun safeSegments(segs: List<String>?): List<String> =
        (segs ?: emptyList()).map { it.trim() }.filter { it.isNotEmpty() && it != "." && it != ".." && !it.contains('/') }

    private fun guessMime(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    private fun baseFolder(kind: String): String = when (kind) {
        "image" -> Environment.DIRECTORY_PICTURES
        "video" -> Environment.DIRECTORY_MOVIES
        "audio" -> Environment.DIRECTORY_MUSIC
        else -> Environment.DIRECTORY_DOWNLOADS
    }

    private fun relativePath(kind: String, relDir: List<String>): String =
        (listOf(baseFolder(kind), "SwiftDrop") + relDir).joinToString("/")

    private fun collection(kind: String): Uri {
        val vol = MediaStore.VOLUME_EXTERNAL_PRIMARY
        return when (kind) {
            "image" -> MediaStore.Images.Media.getContentUri(vol)
            "video" -> MediaStore.Video.Media.getContentUri(vol)
            "audio" -> MediaStore.Audio.Media.getContentUri(vol)
            else -> MediaStore.Downloads.getContentUri(vol)
        }
    }

    private fun publishMediaStore(
        src: File, kind: String, relDir: List<String>, name: String, mime: String, modified: Long, replace: Boolean,
    ): Map<String, Any?> {
        val col = collection(kind)
        val rel = relativePath(kind, relDir)
        if (replace) findMediaStore(col, rel, name)?.let { resolver.delete(it, null, null) }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(col, values) ?: throw IOException("could not create entry")
        try {
            copyTo(src, uri)
            val done = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
                if (modified > 0) put(MediaStore.MediaColumns.DATE_MODIFIED, modified / 1000)
            }
            resolver.update(uri, done, null, null)
            if (modified > 0) keepModified(uri, modified)
        } catch (e: Exception) {
            try { resolver.delete(uri, null, null) } catch (_: Exception) {}
            throw e
        }
        val stored = displayName(uri) ?: name
        return mapOf("display" to "$rel/$stored", "uri" to uri.toString())
    }

    /** MediaStore stamps "now" when it publishes; put the original modification time back. */
    private fun keepModified(uri: Uri, modified: Long) {
        try {
            resolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0)?.let { File(it).setLastModified(modified) }
            }
            val v = ContentValues().apply { put(MediaStore.MediaColumns.DATE_MODIFIED, modified / 1000) }
            resolver.update(uri, v, null, null)
        } catch (_: Exception) {
            // not fatal: the file is complete and visible, just stamped with the arrival time
        }
    }

    private fun findMediaStore(col: Uri, rel: String, name: String): Uri? {
        val sel = "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?"
        resolver.query(col, arrayOf(MediaStore.MediaColumns._ID), sel, arrayOf(name, "$rel/"), null)?.use { c ->
            if (c.moveToFirst()) return ContentUris.withAppendedId(col, c.getLong(0))
        }
        return null
    }

    private fun displayName(uri: Uri): String? =
        resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    /** Android 7-9: write into the public folder (WRITE_EXTERNAL_STORAGE is granted first), then scan. */
    @Suppress("DEPRECATION")
    private fun publishLegacy(
        src: File, kind: String, relDir: List<String>, name: String, mime: String, modified: Long, replace: Boolean,
    ): Map<String, Any?> {
        val dir = File(File(Environment.getExternalStoragePublicDirectory(baseFolder(kind)), "SwiftDrop"), relDir.joinToString("/"))
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("could not create folder")
        var dest = File(dir, name)
        if (dest.exists() && replace) dest.delete()
        var n = 2
        while (dest.exists()) {
            val dot = name.lastIndexOf('.')
            dest = File(dir, if (dot > 0) "${name.substring(0, dot)} ($n)${name.substring(dot)}" else "$name ($n)")
            n++
        }
        val tmp = File(dir, ".${dest.name}.part")
        try {
            FileInputStream(src).channel.use { inp ->
                FileOutputStream(tmp).channel.use { out -> pump(inp, out) }
            }
            if (!tmp.renameTo(dest)) throw IOException("could not finish file")
        } catch (e: Exception) {
            tmp.delete()
            throw e
        }
        if (modified > 0) dest.setLastModified(modified)
        MediaScannerConnection.scanFile(activity, arrayOf(dest.path), arrayOf(mime), null)
        return mapOf("display" to relativePath(kind, relDir) + "/" + dest.name, "uri" to Uri.fromFile(dest).toString())
    }

    private fun copyTo(src: File, uri: Uri) {
        val pfd = resolver.openFileDescriptor(uri, "w") ?: throw IOException("could not open destination")
        pfd.use {
            FileInputStream(src).channel.use { inp ->
                FileOutputStream(it.fileDescriptor).channel.use { out -> pump(inp, out) }
                // "Complete" has to mean on disk: without this a crash or battery pull right
                // after the success screen loses the tail of a big file the sender already
                // saw verified. Small files skip it (a per-file sync would slow 1000 photos).
                if (inp.size() >= SYNC_FROM) {
                    try { it.fileDescriptor.sync() } catch (_: Exception) {}
                }
            }
        }
    }

    /** Kernel-side copy first; a plain 1 MiB buffer loop if the destination refuses it. */
    private fun pump(inp: FileChannel, out: FileChannel) {
        val size = inp.size()
        var pos = 0L
        while (pos < size) {
            val n = inp.transferTo(pos, minOf(size - pos, 8L shl 20), out)
            if (n <= 0) break
            pos += n
        }
        if (pos < size) {
            val buf = ByteBuffer.allocateDirect(1 shl 20)
            inp.position(pos)
            while (inp.read(buf) >= 0) {
                buf.flip()
                while (buf.hasRemaining()) out.write(buf)
                buf.clear()
            }
        }
    }

    // ------------------------------------------------------------------ SAF tree

    private fun publishTree(src: File, tree: Uri, relDir: List<String>, name: String, mime: String, replace: Boolean): Map<String, Any?> {
        val parent = folder(tree, relDir, create = true)!!
        if (replace) childByName(tree, parent, name)?.let { DocumentsContract.deleteDocument(resolver, it) }
        val doc = DocumentsContract.createDocument(resolver, parent, mime, name) ?: throw IOException("could not create file")
        try {
            copyTo(src, doc)
        } catch (e: Exception) {
            try { DocumentsContract.deleteDocument(resolver, doc) } catch (_: Exception) {}
            throw e
        }
        val stored = resolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        } ?: name
        return mapOf("display" to (relDir + stored).joinToString("/"), "uri" to doc.toString())
    }

    private fun root(tree: Uri): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    private fun folder(tree: Uri, relDir: List<String>, create: Boolean): Uri? {
        var cur = root(tree)
        var key = tree.toString()
        for (seg in relDir) {
            key += "/$seg"
            val cached = folders[key]
            if (cached != null) {
                cur = cached
                continue
            }
            val found = childByName(tree, cur, seg)
            cur = found ?: if (create) {
                DocumentsContract.createDocument(resolver, cur, DocumentsContract.Document.MIME_TYPE_DIR, seg)
                    ?: throw IOException("could not create folder")
            } else {
                return null
            }
            folders[key] = cur
        }
        return cur
    }

    private fun childByName(tree: Uri, parent: Uri, name: String): Uri? {
        val kids = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
        resolver.query(
            kids,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) == name) return DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0))
            }
        }
        return null
    }

    private fun exists(call: MethodCall): Boolean {
        val name = call.argument<String>("name")!!
        val kind = call.argument<String>("kind") ?: "file"
        val target = call.argument<String>("target") ?: "downloads"
        val relDir = safeSegments(call.argument<List<String>>("relDir"))
        val tree = call.argument<String>("tree")
        return try {
            val k = if (target == "gallery") kind else "file"
            if (target == "tree" && tree != null) {
                val t = Uri.parse(tree)
                val parent = folder(t, relDir, create = false) ?: return false
                childByName(t, parent, name) != null
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                findMediaStore(collection(k), relativePath(k, relDir), name) != null
            } else {
                @Suppress("DEPRECATION")
                File(File(File(Environment.getExternalStoragePublicDirectory(baseFolder(k)), "SwiftDrop"), relDir.joinToString("/")), name).exists()
            }
        } catch (e: Exception) {
            false
        }
    }

    // ------------------------------------------------------------------ folder picker

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "picker already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
        )
        // Open at Documents: the storage root can't be chosen on Android 11+, so starting
        // there only leads to a "can't use this folder" wall.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            intent.putExtra(
                DocumentsContract.EXTRA_INITIAL_URI,
                DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:Documents"),
            )
        }
        try {
            activity.startActivityForResult(intent, REQ_TREE)
        } catch (e: Exception) {
            pendingPick = null
            result.error("noPicker", "No folder picker on this device", null)
        }
    }

    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != REQ_TREE) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            folders.clear()
            val name = resolver.query(root(uri), arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
            result.success(mapOf("uri" to uri.toString(), "name" to (name ?: "Chosen folder")))
        } catch (e: Exception) {
            result.error("grant", e.message, null)
        }
        return true
    }

    private fun folderGranted(uri: String?): Boolean =
        uri != null && resolver.persistedUriPermissions.any { it.uri.toString() == uri && it.isWritePermission }

    private fun releaseFolder(uri: String?) {
        if (uri == null) return
        try {
            resolver.releasePersistableUriPermission(
                Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (_: Exception) {
        }
        folders.clear()
    }

    // ------------------------------------------------------------------ "view files"

    private fun openIntent(what: String?, uri: String?): Intent? = when (what) {
        "gallery" -> Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_GALLERY)
        "downloads" -> Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
        "folder" -> uri?.let {
            Intent(Intent.ACTION_VIEW).setDataAndType(root(Uri.parse(it)), DocumentsContract.Document.MIME_TYPE_DIR)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        else -> null
    }

    private fun canOpen(what: String?, uri: String?): Boolean {
        val i = openIntent(what, uri) ?: return false
        return i.resolveActivity(activity.packageManager) != null
    }

    private fun open(what: String?, uri: String?): Boolean {
        val i = openIntent(what, uri) ?: return false
        return try {
            if (what == "gallery") {
                // Gallery app if the device has one, else the system image viewer.
                val main = Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_GALLERY)
                activity.startActivity(main.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } else {
                activity.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    companion object {
        const val REQ_TREE = 7311
        const val SYNC_FROM = 4L shl 20
    }
}
