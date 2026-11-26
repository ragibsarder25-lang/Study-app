"""Adds native AlarmManager + BroadcastReceiver alarms to the generated Android project.
Usage: python3 tools/native_alarm.py android
"""
import os, sys

root = sys.argv[1]
pkg_dir = os.path.join(root, "app/src/main/kotlin/com/example/recursive_study")
os.makedirs(pkg_dir, exist_ok=True)

ALARMS = '''package com.example.recursive_study

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build

object Alarms {
    const val CHANNEL = "study_alarm_native"
    private const val PREF = "native_alarms"

    private fun pending(ctx: Context, id: Int, title: String, body: String): PendingIntent {
        val i = Intent(ctx, AlarmReceiver::class.java)
            .putExtra("id", id).putExtra("title", title).putExtra("body", body)
        return PendingIntent.getBroadcast(
            ctx, id, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun openApp(ctx: Context): PendingIntent? {
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: return null
        return PendingIntent.getActivity(
            ctx, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun schedule(ctx: Context, id: Int, whenMs: Long, title: String, body: String, persist: Boolean = true) {
        if (whenMs <= System.currentTimeMillis()) return
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(ctx, id, title, body)
        try {
            val show = openApp(ctx) ?: pi
            am.setAlarmClock(AlarmManager.AlarmClockInfo(whenMs, show), pi)
        } catch (e: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenMs, pi)
        }
        if (persist) {
            ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit()
                .putString("a$id", "$whenMs\\u0001$title\\u0001$body").apply()
        }
    }

    fun cancel(ctx: Context, id: Int) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pending(ctx, id, "", ""))
        forget(ctx, id)
    }

    fun cancelAll(ctx: Context) {
        val p = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        for (k in p.all.keys.toList()) {
            if (k.startsWith("a")) k.substring(1).toIntOrNull()?.let { cancel(ctx, it) }
        }
        p.edit().clear().apply()
    }

    fun forget(ctx: Context, id: Int) {
        ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().remove("a$id").apply()
    }

    fun restoreAll(ctx: Context) {
        val p = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        for ((k, v) in p.all) {
            val parts = (v as? String)?.split("\\u0001") ?: continue
            val id = k.removePrefix("a").toIntOrNull() ?: continue
            val t = parts.getOrNull(0)?.toLongOrNull() ?: continue
            if (t > now) schedule(ctx, id, t, parts.getOrElse(1) { "" }, parts.getOrElse(2) { "" }, false)
            else forget(ctx, id)
        }
    }

    fun notify(ctx: Context, id: Int, title: String, body: String) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val b: android.app.Notification.Builder
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL, "Study alarms", NotificationManager.IMPORTANCE_HIGH)
            ch.setSound(sound, AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            ch.enableVibration(true)
            ch.vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 600)
            ch.lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            nm.createNotificationChannel(ch)
            b = android.app.Notification.Builder(ctx, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            b = android.app.Notification.Builder(ctx).setSound(sound)
                .setVibrate(longArrayOf(0, 600, 300, 600, 300, 600))
                .setPriority(android.app.Notification.PRIORITY_MAX)
        }
        b.setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(android.app.Notification.BigTextStyle().bigText(body))
            .setCategory(android.app.Notification.CATEGORY_ALARM)
            .setAutoCancel(true)
        openApp(ctx)?.let { b.setContentIntent(it) }
        nm.notify(id, b.build())
    }
}
'''

RECEIVER = '''package com.example.recursive_study

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra("id", 0)
        val title = intent.getStringExtra("title") ?: "StudyOS"
        val body = intent.getStringExtra("body") ?: ""
        try {
            Alarms.notify(context, id, title, body)
        } finally {
            Alarms.forget(context, id)
        }
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Alarms.restoreAll(context)
    }
}
'''

ACTIVITY = '''package com.example.recursive_study

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "study/alarm")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "schedule" -> {
                            Alarms.schedule(
                                this,
                                call.argument<Int>("id")!!,
                                call.argument<Number>("when")!!.toLong(),
                                call.argument<String>("title") ?: "",
                                call.argument<String>("body") ?: "")
                            result.success(true)
                        }
                        "cancel" -> {
                            Alarms.cancel(this, call.argument<Int>("id")!!)
                            result.success(true)
                        }
                        "cancelAll" -> {
                            Alarms.cancelAll(this)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("alarm", e.message, null)
                }
            }
    }
}
'''

for name, text in (("Alarms.kt", ALARMS), ("AlarmReceiver.kt", RECEIVER), ("MainActivity.kt", ACTIVITY)):
    with open(os.path.join(pkg_dir, name), "w") as f:
        f.write(text)

# Remove any scaffold MainActivity.java so there is only one MainActivity
for dp, _, fs in os.walk(os.path.join(root, "app/src/main")):
    for fn in fs:
        if fn == "MainActivity.java":
            os.remove(os.path.join(dp, fn))

mf = os.path.join(root, "app/src/main/AndroidManifest.xml")
s = open(mf).read()
if ".AlarmReceiver" not in s:
    block = """
        <receiver android:name="com.example.recursive_study.AlarmReceiver" android:exported="false" />
        <receiver android:name="com.example.recursive_study.BootReceiver" android:exported="false">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
"""
    s = s.replace("</application>", block + "    </application>", 1)
    open(mf, "w").write(s)
print("native alarm added")
