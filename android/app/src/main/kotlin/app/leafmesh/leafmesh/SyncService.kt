package app.leafmesh.leafmesh

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import leafmeshbridge.Leafmeshbridge

class SyncService : Service() {
    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("sync", "后台同步", NotificationManager.IMPORTANCE_LOW))
        val intent = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        startForeground(7001, NotificationCompat.Builder(this, "sync").setContentTitle("Leafmesh 正在保持同步")
            .setContentText("点击打开文件；系统限制后会在下次打开时补同步")
            .setSmallIcon(android.R.drawable.stat_notify_sync).setContentIntent(intent).setOngoing(true).build())
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY
    override fun onTimeout(startId: Int, fgsType: Int) {
        Thread { CoreRuntime.stop() }.start()
        stopSelf()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
