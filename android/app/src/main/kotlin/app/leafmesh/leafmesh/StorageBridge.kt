package app.leafmesh.leafmesh

import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import androidx.documentfile.provider.DocumentFile
import leafmeshbridge.Storage
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID

/** SAF operations use persisted, explicitly granted tree URIs only. */
class StorageBridge(private val context: Context) : Storage {
    private val resolver = context.contentResolver
    private val journals = File(context.filesDir, "saf-replacements").apply { mkdirs() }

    private fun parts(value: String): List<String> {
        if (value.isEmpty() || value == ".") return emptyList()
        require(!value.startsWith('/') && !value.contains('\\') && !value.contains('\u0000')) { "无效的相对路径" }
        return value.split('/').also { list -> require(list.none { it.isEmpty() || it == "." || it == ".." }) { "路径不能越出共享目录" } }
    }
    private fun tree(root: String): DocumentFile {
        val uri = Uri.parse(Uri.decode(root))
        require(uri.scheme == "content") { "无效的文档目录" }
        require(uri.authority == "com.android.externalstorage.documents" || uri.authority == "com.android.providers.downloads.documents") {
            "当前仅支持设备本地目录，请不要选择云盘提供器"
        }
        val granted = resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission }
        if (!granted) throw SecurityException("目录授权已失效，请重新选择该目录")
        return DocumentFile.fromTreeUri(context, uri)?.takeIf { it.exists() && it.isDirectory }
            ?: throw FileNotFoundException("目录暂时不可用")
    }
    private fun document(root: String, path: String): DocumentFile {
        var current = tree(root)
        for (part in parts(path)) current = current.findFile(part) ?: throw FileNotFoundException(path)
        return current
    }
    fun uri(root: String, path: String): Uri = document(root, path).uri
    private fun parent(root: String, path: String): Pair<DocumentFile, String> {
        val segments = parts(path)
        require(segments.isNotEmpty()) { "不能修改共享根目录本身" }
        return document(root, segments.dropLast(1).joinToString("/")) to segments.last()
    }
    private fun create(root: String, path: String, directory: Boolean, all: Boolean = false): DocumentFile {
        if (all) {
            var current = tree(root)
            for (part in parts(path)) {
                current = current.findFile(part)?.also { require(it.isDirectory) } ?: current.createDirectory(part)
                    ?: error("无法创建目录：$part")
            }
            return current
        }
        val (parent, name) = parent(root, path)
        if (parent.findFile(name) != null) throw java.nio.file.FileAlreadyExistsException(path)
        val item = (if (directory) parent.createDirectory(name) else parent.createFile("application/octet-stream", name))
            ?: error("无法创建文件：$path")
        if (item.name != name) { item.delete(); error("目录提供器修改了文件名，已停止写入") }
        return item
    }

    @Synchronized override fun request(requestJSON: String): String {
        return try {
            val request = JSONObject(requestJSON)
            val root = request.getString("root")
            val path = request.optString("path")
            val result: Any? = when (request.getString("op")) {
                "stat" -> document(root, path).let { JSONObject(mapOf("name" to it.name, "size" to it.length(), "modified" to it.lastModified(), "directory" to it.isDirectory)) }
                "names" -> JSONArray(document(root, path).listFiles().map { it.name ?: error("文件缺少名称") })
                "mkdir" -> { create(root, path, true); null }
                "mkdirAll" -> { create(root, path, true, true); null }
                "open" -> {
                    val flags = request.getInt("flags")
                    val existing = try { document(root, path) } catch (_: FileNotFoundException) { null }
                    if (existing != null && flags and 128 != 0 && flags and 64 != 0) throw java.nio.file.FileAlreadyExistsException(path)
                    val file = existing ?: if (flags and 64 != 0) create(root, path, false) else throw FileNotFoundException(path)
                    require(!file.isDirectory) { "不能将目录作为文件打开" }
                    val writing = flags and 3 != 0
                    val mode = if (!writing) "r" else if (flags and 1024 != 0) "wa" else if (flags and 512 != 0) "rwt" else "rw"
                    resolver.openFileDescriptor(file.uri, mode)?.detachFd()?.toLong() ?: error("无法打开文档描述符")
                }
                "remove" -> { remove(root, path, request.optBoolean("recursive")); null }
                "rename" -> { rename(root, path, request.getString("target"), request.optBoolean("replace")); null }
                "touch" -> { document(root, path); null } // Syncthing's virtual-mtime wrapper handles provider times.
                "usage" -> {
                    val treeId = android.provider.DocumentsContract.getTreeDocumentId(Uri.parse(Uri.decode(root)))
                    val volume = if (Uri.parse(Uri.decode(root)).authority == "com.android.externalstorage.documents") treeId.substringBefore(':') else "primary"
                    val disk = if (volume.equals("primary", true) || volume == "downloads") Environment.getExternalStorageDirectory() else File("/storage/$volume")
                    val stat = StatFs(disk.absolutePath)
                    JSONObject(mapOf("free" to stat.availableBytes, "total" to stat.totalBytes))
                }
                else -> error("未知存储操作")
            }
            JSONObject().put("result", result ?: JSONObject.NULL).toString()
        } catch (error: Throwable) {
            val code = when(error) {
                is FileNotFoundException -> "notFound"
                is SecurityException -> "permission"
                is java.nio.file.FileAlreadyExistsException -> "exists"
                else -> "io"
            }
            JSONObject().put("error", error.message ?: "目录操作失败").put("code", code).toString()
        }
    }

    fun list(root: String, path: String): List<Map<String, Any?>> = document(root, path).listFiles().map { item ->
        val name = item.name ?: error("文件缺少名称")
        mapOf("path" to (parts(path) + name).joinToString("/"), "directory" to item.isDirectory,
            "size" to item.length(), "modified" to item.lastModified())
    }
    fun read(root: String, path: String): ByteArray {
        val item = document(root, path)
        require(item.length() <= 16 * 1024 * 1024) { "文件超过 16 MiB，请使用外部应用打开" }
        return resolver.openInputStream(item.uri)?.use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(output.size() + count <= 16 * 1024 * 1024) { "文件过大" }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: error("无法读取文件")
    }
    private fun hash(input: InputStream): String = input.use {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1024 * 1024)
        while (true) { val read = it.read(buffer); if (read < 0) break; digest.update(buffer, 0, read) }
        digest.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 255) }
    }
    private fun digest(root: String, path: String): String = hash(resolver.openInputStream(document(root, path).uri) ?: error("无法读取文件"))

    @Synchronized fun write(root: String, path: String, bytes: ByteArray, expected: String?, createOnly: Boolean) {
        val existing = try { document(root, path) } catch (_: FileNotFoundException) { null }
        if (existing != null && (createOnly || expected == null || digest(root, path) != expected)) error("文件已有新的修改，草稿已保留，请先处理差异")
        if (existing == null && expected != null) error("文件已被删除，草稿已保留")
        val prefix = parts(path).dropLast(1)
        val temporaryPath = (prefix + ".syncthing.leafmesh-write-${UUID.randomUUID()}.tmp").joinToString("/")
        val temporary = create(root, temporaryPath, false)
        try {
            resolver.openOutputStream(temporary.uri, "wt")?.use { it.write(bytes); it.flush() } ?: error("无法写入临时文件")
            val current = try { document(root, path) } catch (_: FileNotFoundException) { null }
            if (current != null && (expected == null || digest(root, path) != expected)) error("保存期间检测到新修改，已保留草稿")
            if (current == null && expected != null) error("保存期间文件被删除，已保留草稿")
            rename(root, temporaryPath, path, expected != null)
        } finally {
            // Some providers keep the same document ID after rename. Looking up
            // the old temporary *name* avoids deleting the committed target.
            try { document(root, temporaryPath).delete() }
            catch (_: FileNotFoundException) { /* It was committed by rename. */ }
            catch (_: SecurityException) { /* Preserve data until permission is restored. */ }
        }
    }

    @Synchronized fun rename(root: String, from: String, to: String, replace: Boolean) {
        val oldParts = parts(from); val newParts = parts(to)
        require(oldParts.isNotEmpty() && newParts.isNotEmpty() && oldParts.dropLast(1) == newParts.dropLast(1)) { "只支持同一目录中的重命名" }
        val source = document(root, from)
        val (parent, name) = parent(root, to)
        val target = parent.findFile(name)
        if (target != null && !replace) throw java.nio.file.FileAlreadyExistsException(to)
        var backup: DocumentFile? = null
        var journal: File? = null
        if (target != null) {
            require(!target.isDirectory) { "不能覆盖目录" }
            val backupName = ".syncthing.leafmesh-backup-${UUID.randomUUID()}.tmp"
            journal = File(journals, "${UUID.randomUUID()}.json")
            journal.writeText(JSONObject(mapOf("root" to root, "target" to to,
                "backup" to (newParts.dropLast(1) + backupName).joinToString("/"))).toString())
            if (!target.renameTo(backupName)) error("无法暂存旧版本")
            backup = target
        }
        if (!source.renameTo(name)) {
            backup?.renameTo(name)
            error("文件替换失败，旧内容已保留")
        }
        backup?.delete()
        journal?.delete()
    }

    @Synchronized fun remove(root: String, path: String, recursive: Boolean) {
        require(parts(path).isNotEmpty()) { "不能删除共享根目录" }
        val target = document(root, path)
        if (!recursive && target.isDirectory && target.listFiles().isNotEmpty()) error("只能删除空文件夹")
        if (!target.delete()) error("删除失败，请检查目录权限")
    }

    fun recover() {
        for (journal in journals.listFiles() ?: emptyArray()) {
            try {
                val record = JSONObject(journal.readText())
                val root = record.getString("root")
                val target = record.getString("target")
                val backup = record.getString("backup")
                val backupFile = try { document(root, backup) } catch (_: FileNotFoundException) { null }
                val targetFile = try { document(root, target) } catch (_: FileNotFoundException) { null }
                if (backupFile != null) {
                    if (targetFile == null) { if (!backupFile.renameTo(parts(target).last())) error("旧文件恢复失败") }
                    else backupFile.delete()
                }
                journal.delete()
            } catch (_: SecurityException) { /* Keep journal until the user restores directory permission. */ }
        }
    }

    fun migrate(source: String, sourceSaf: Boolean, target: String, targetSaf: Boolean) {
        fun local(root: String, relative: String): File {
            val base = File(root).canonicalFile
            val result = File(base, parts(relative).joinToString(File.separator)).canonicalFile
            require(result == base || result.path.startsWith(base.path + File.separator)) { "目录包含越界链接" }
            return result
        }
        fun names(root: String, saf: Boolean, relative: String): List<String> = if (saf) document(root, relative).listFiles().map { it.name!! }
            else local(root, relative).list()?.toList() ?: error("无法读取源目录")
        fun isDir(root: String, saf: Boolean, relative: String) = if (saf) document(root, relative).isDirectory else local(root, relative).isDirectory
        fun input(root: String, saf: Boolean, relative: String): InputStream = if (saf) resolver.openInputStream(document(root, relative).uri) ?: error("无法读取源文件") else local(root, relative).inputStream()
        require(names(target, targetSaf, "").isEmpty()) { "迁移目标目录必须为空" }
        val originals = mutableMapOf<String, String>()
        fun copy(relative: String) {
            for (name in names(source, sourceSaf, relative)) {
                val child = (parts(relative) + name).joinToString("/")
                if (isDir(source, sourceSaf, child)) {
                    if (targetSaf) create(target, child, true) else require(local(target, child).mkdir())
                    copy(child)
                } else {
                    val before = hash(input(source, sourceSaf, child))
                    val output: OutputStream = if (targetSaf) resolver.openOutputStream(create(target, child, false).uri, "wt") ?: error("无法创建目标文件") else local(target, child).outputStream()
                    input(source, sourceSaf, child).use { from -> output.use { to -> from.copyTo(to, 1024 * 1024); to.flush() } }
                    require(hash(input(target, targetSaf, child)) == before) { "迁移文件校验失败：$child" }
                    originals[child] = before
                    if (!sourceSaf && !targetSaf) local(target, child).setLastModified(local(source, child).lastModified())
                }
            }
        }
        copy("")
        val observed = mutableSetOf<String>()
        fun verify(relative: String) {
            for (name in names(source, sourceSaf, relative)) {
                val child = (parts(relative) + name).joinToString("/")
                if (isDir(source, sourceSaf, child)) verify(child)
                else { observed += child; require(originals[child] == hash(input(source, sourceSaf, child))) { "迁移期间源文件发生变化：$child" } }
            }
        }
        verify("")
        require(observed == originals.keys) { "迁移期间源目录内容发生变化" }
    }
}
