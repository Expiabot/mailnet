package fr.mailnet

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Keeps the process alive and the CPU awake while a bulk deletion runs.
 *
 * Without this, leaving the app during a five-thousand message run lets Android
 * freeze or kill it — Samsung's battery manager especially — and the deletion
 * stops halfway. The work itself stays in the Flutter isolate; this service only
 * buys it the right to keep running, and shows the user what is happening.
 */
class DeleteForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val deleted = intent?.getIntExtra(EXTRA_DELETED, 0) ?: 0
        val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0

        createChannel(this)
        startInForeground(buildNotification(this, deleted, total))
        acquireWakeLock()

        // Restarting with an empty intent would show a meaningless 0/0.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startInForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        // A foreground service keeps the process; only a wake lock keeps the CPU
        // running once the screen goes off mid-deletion.
        wakeLock = power.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "MailNet::delete",
        ).apply {
            setReferenceCounted(false)
            acquire(MAX_RUNTIME_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    companion object {
        const val CHANNEL_ID = "mailnet_delete"
        const val NOTIFICATION_ID = 4711
        const val EXTRA_DELETED = "deleted"
        const val EXTRA_TOTAL = "total"

        /** Safety net: the lock is released on stop, this only caps a leak. */
        private const val MAX_RUNTIME_MS = 30 * 60 * 1000L

        fun start(context: Context, deleted: Int, total: Int) {
            val intent = Intent(context, DeleteForegroundService::class.java)
                .putExtra(EXTRA_DELETED, deleted)
                .putExtra(EXTRA_TOTAL, total)
            context.startForegroundService(intent)
        }

        /**
         * Redraws the existing notification in place.
         *
         * Deliberately *not* another startForegroundService: from Android 12 a
         * service may not be started from the background, and progress ticks
         * keep coming after the user has left the app.
         */
        fun update(context: Context, deleted: Int, total: Int) {
            createChannel(context)
            try {
                NotificationManagerCompat.from(context)
                    .notify(NOTIFICATION_ID, buildNotification(context, deleted, total))
            } catch (_: SecurityException) {
                // Notifications denied on Android 13+. The service still runs,
                // which is the part that matters.
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DeleteForegroundService::class.java))
        }

        private fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Suppression en cours",
                // LOW: the notification must be visible, never make a sound.
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Progression des suppressions de mails"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        private fun buildNotification(context: Context, deleted: Int, total: Int): Notification {
            val openApp = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                },
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )

            val text = if (total > 0) "$deleted mails sur $total" else "Préparation…"

            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle("MailNet — suppression en cours")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setProgress(maxOf(total, 1), deleted, total == 0)
                .setContentIntent(openApp)
                .build()
        }
    }
}
