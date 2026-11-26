package app.leafmesh.leafmesh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import leafmeshbridge.Leafmeshbridge
import java.util.concurrent.Executors
import java.io.File

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var picker: MethodChannel.Result? = null
    private lateinit var storage: StorageBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        storage = StorageBridge(applicationContext)
        CoreRuntime.initialize(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.leafmesh/platform").setMethodCallHandler { call, result ->
            if (call.method == "pickDirectory") {
                if (picker != null) { result.error("PICKER_BUSY", "目录选择器已打开", null); return@setMethodCallHandler }
                picker = result
                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }, 4101)
                return@setMethodCallHandler
            }
            if (call.method == "setBackground") {
                val enabled = call.argument<Boolean>("enabled") == true
                if (enabled && Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4102)
                    result.error("NOTIFICATION_PERMISSION", "请允许通知后再次启用后台同步", null)
                    return@setMethodCallHandler
                }
                try {
                    if (enabled) ContextCompat.startForegroundService(this, Intent(this, SyncService::class.java))
                    else stopService(Intent(this, SyncService::class.java))
                    getSharedPreferences("runtime", MODE_PRIVATE).edit().putBoolean("background", enabled).apply()
                    result.success(null)
                } catch (error: RuntimeException) {
                    result.error("BACKGROUND_RESTRICTED", "系统暂不允许后台服务，请在前台重新启用：${error.message}", null)
                }
                return@setMethodCallHandler
            }
            worker.execute {
                try {
                    if (call.method == "storageOpen") {
                        val root = call.argument<String>("root")!!
                        val path = call.argument<String>("path")!!
                        val uri = if (call.argument<Boolean>("saf") == true) storage.uri(root, path) else {
                            val allowed = File(filesDir, "folders").canonicalFile
                            val base = File(root).canonicalFile
                            val target = File(base, path).canonicalFile
                            require(base.path.startsWith(allowed.path + File.separator)) { "只能打开共享文件夹中的文件" }
                            require(target.path.startsWith(base.path + File.separator) && target.isFile) { "文件不存在或越出共享目录" }
                            FileProvider.getUriForFile(this, "$packageName.files", target)
                        }
                        runOnUiThread {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(uri, contentResolver.getType(uri) ?: "application/octet-stream")
                                    .apply {
                                        clipData = android.content.ClipData.newRawUri("Leafmesh file", uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    })
                                result.success(null)
                            } catch (error: RuntimeException) {
                                result.error("FILE_OPEN_FAILED", "无法打开此文件，请安装支持该格式的应用：${error.message}", null)
                            }
                        }
                        return@execute
                    }
                    val value: Any? = when (call.method) {
                        "startCore" -> {
                            CoreRuntime.start(call.argument<String>("home")!!, call.argument<Int>("port")!!.toLong(), call.argument<String>("key")!!, storage)
                        }
                        "stopCore" -> { CoreRuntime.stop(); null }
                        "storageList" -> storage.list(call.argument<String>("root")!!, call.argument<String>("path") ?: "")
                        "storageRead" -> storage.read(call.argument<String>("root")!!, call.argument<String>("path")!!)
                        "storageWrite" -> { storage.write(call.argument<String>("root")!!, call.argument<String>("path")!!,
                            call.argument<ByteArray>("bytes")!!, call.argument<String>("expectedHash"), call.argument<Boolean>("createOnly") == true); null }
                        "storageMkdir" -> { storage.request(org.json.JSONObject(mapOf("op" to "mkdir", "root" to call.argument<String>("root"), "path" to call.argument<String>("path"))).toString()).let {
                            val response = org.json.JSONObject(it); if (response.has("error")) error(response.getString("error"))
                        }; null }
                        "storageRename" -> { storage.rename(call.argument<String>("root")!!, call.argument<String>("path")!!, call.argument<String>("target")!!, false); null }
                        "storageDelete" -> { storage.remove(call.argument<String>("root")!!, call.argument<String>("path")!!, false); null }
                        "migrateStorage" -> { storage.migrate(call.argument<String>("root")!!, call.argument<Boolean>("sourceSaf") == true,
                            call.argument<String>("target")!!, call.argument<Boolean>("targetSaf") == true); null }
                        else -> throw UnsupportedOperationException(call.method)
                    }
                    runOnUiThread { result.success(value) }
                } catch (error: Throwable) {
                    runOnUiThread { result.error("PLATFORM_ERROR", error.message ?: error.javaClass.simpleName, null) }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        worker.execute { try { CoreRuntime.resume() } catch (_: Throwable) { /* UI reports failed API reconnection. */ } }
    }
    override fun onStop() {
        super.onStop()
        if (!getSharedPreferences("runtime", MODE_PRIVATE).getBoolean("background", false)) {
            worker.execute { CoreRuntime.stop() }
        }
    }

    @Deprecated("Deprecated by Android, retained for the directory picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 4101) {
            val pending = picker ?: return
            picker = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) { pending.success(null); return }
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                pending.success(uri.toString())
            } catch (error: SecurityException) { pending.error("DIRECTORY_PERMISSION", "该目录无法获得持续读写权限，请选择其他本地目录", null) }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
