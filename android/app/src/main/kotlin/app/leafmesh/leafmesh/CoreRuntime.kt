package app.leafmesh.leafmesh

import leafmeshbridge.Leafmeshbridge
import android.content.Context
import android.net.wifi.WifiManager

/** Process-wide ownership survives Flutter activity recreation. */
object CoreRuntime {
    private var home: String? = null
    private var port: Long = 0
    private var key: String? = null
    private var storage: StorageBridge? = null
    private var context: Context? = null
    private var multicast: WifiManager.MulticastLock? = null
    fun initialize(context: Context) { this.context = context.applicationContext }
    private fun keepDiscoveryAvailable() {
        if (multicast?.isHeld == true) return
        try {
            val manager = context?.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            multicast = manager.createMulticastLock("Leafmesh discovery").apply { setReferenceCounted(false); acquire() }
        } catch (error: RuntimeException) {
            android.util.Log.w("Leafmesh", "Wi-Fi multicast is unavailable; other discovery methods remain enabled", error)
        }
    }
    @Synchronized fun start(requestHome: String, requestPort: Long, requestKey: String, requestStorage: StorageBridge): Long {
        if (Leafmeshbridge.running()) return port
        home = requestHome; port = requestPort; key = requestKey; storage = requestStorage
        requestStorage.recover()
        Leafmeshbridge.start(requestHome, requestPort, requestKey, requestStorage)
        keepDiscoveryAvailable()
        return port
    }
    @Synchronized fun resume() {
        val path = home ?: return
        val secret = key ?: return
        val provider = storage ?: return
        if (!Leafmeshbridge.running()) { Leafmeshbridge.start(path, port, secret, provider); keepDiscoveryAvailable() }
    }
    @Synchronized fun stop() {
        Leafmeshbridge.stop()
        if (multicast?.isHeld == true) multicast?.release()
        multicast = null
    }
}
