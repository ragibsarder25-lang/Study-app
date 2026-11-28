import sys
f = sys.argv[1]
s = open(f).read()
perms = [
    "INTERNET", "POST_NOTIFICATIONS", "SCHEDULE_EXACT_ALARM", "USE_EXACT_ALARM", "RECEIVE_BOOT_COMPLETED",
    "VIBRATE", "WAKE_LOCK", "USE_FULL_SCREEN_INTENT", "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
]
p = "".join('    <uses-permission android:name="android.permission.%s"/>\n' % x for x in perms)
receivers = """
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
"""
s = s.replace("<application", p + "    <application", 1)
s = s.replace("</application>", receivers + "    </application>", 1)
s = s.replace('android:label="recursive_study"', 'android:label="Recursive Study"')
open(f, "w").write(s)
