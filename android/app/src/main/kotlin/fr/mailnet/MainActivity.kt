package fr.mailnet

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        DeleteForegroundService.start(
                            this,
                            call.argument<Int>("deleted") ?: 0,
                            call.argument<Int>("total") ?: 0,
                        )
                        result.success(null)
                    }

                    "update" -> {
                        DeleteForegroundService.update(
                            this,
                            call.argument<Int>("deleted") ?: 0,
                            call.argument<Int>("total") ?: 0,
                        )
                        result.success(null)
                    }

                    "stop" -> {
                        DeleteForegroundService.stop(this)
                        result.success(null)
                    }

                    "requestNotificationPermission" ->
                        result.success(requestNotificationPermission())

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * From Android 13 the progress notification needs an explicit grant. The
     * service runs either way — this only decides whether the user can see it —
     * so the prompt is fired and not awaited.
     */
    private fun requestNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
        }
        return granted
    }

    companion object {
        private const val CHANNEL = "fr.mailnet/background"
        private const val NOTIFICATION_PERMISSION_REQUEST = 4712
    }
}
