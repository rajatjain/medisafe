package `in`.medisafe.medisafe

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    private var preview: MediaPlayer? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        ReminderEngine.createChannel(this)
        MethodChannel(engine.dartExecutor.binaryMessenger, "medisafe/reminders")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "configure" -> {
                            ReminderEngine.configure(this, call.arguments as Map<*, *>)
                            result.success(null)
                        }
                        "events" -> result.success(ReminderEngine.events(this))
                        "acknowledge" -> {
                            ReminderEngine.acknowledge(this, call.arguments as List<*>)
                            result.success(null)
                        }
                        "snoozes" -> result.success(ReminderEngine.snoozes(this))
                        "snooze" -> result.success(ReminderEngine.snooze(
                            this, call.argument<String>("id")!!, call.argument<Int>("minutes")!!,
                        ))
                        "readiness" -> result.success(mapOf(
                            "notifications" to ReminderEngine.canNotify(this),
                            "exact" to ReminderEngine.exact(this),
                        ))
                        "requestNotifications" -> requestNotifications(result)
                        "requestExact" -> {
                            if (Build.VERSION.SDK_INT >= 31 && !ReminderEngine.exact(this)) {
                                startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                            }
                            result.success(null)
                        }
                        "playSound" -> {
                            preview?.release()
                            preview = MediaPlayer.create(this, R.raw.pill_rattle)?.apply {
                                setOnCompletionListener {
                                    it.release()
                                    if (preview === it) preview = null
                                }
                                start()
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("REMINDER_ERROR", "Could not update Android reminders.", null)
                }
            }
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            (!getPreferences(MODE_PRIVATE).getBoolean("asked_notifications", false) ||
                shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))) {
            if (permissionResult != null) {
                result.success(null)
                return
            }
            permissionResult = result
            getPreferences(MODE_PRIVATE).edit().putBoolean("asked_notifications", true).apply()
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41)
        } else {
            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            result.success(null)
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == 41) {
            permissionResult?.success(null)
            permissionResult = null
        }
    }

    override fun onDestroy() {
        preview?.release()
        preview = null
        super.onDestroy()
    }
}

class SnoozeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        }
        val id = intent.getStringExtra(ReminderEngine.ID)
        if (id == null) {
            finish()
            return
        }
        val choices = runCatching { ReminderEngine.choices(this, id) }.getOrDefault(emptyList())
        val dialog = AlertDialog.Builder(this).setTitle("Snooze this dose")
            .setNegativeButton("Cancel") { _, _ -> finish() }
            .setOnCancelListener { finish() }
        if (choices.isEmpty()) {
            dialog.setMessage("The snooze window has ended.")
        } else {
            dialog.setItems(choices.map {
                when (it) {
                    60 -> "1 hour"
                    120 -> "2 hours"
                    else -> "$it minutes"
                }
            }.toTypedArray()) { _, index ->
                val saved = runCatching { ReminderEngine.snooze(this, id, choices[index]) }.getOrDefault(false)
                if (!saved) Toast.makeText(this, "This dose can no longer be snoozed.", Toast.LENGTH_SHORT).show()
                finish()
            }
        }
        dialog.show()
    }
}
