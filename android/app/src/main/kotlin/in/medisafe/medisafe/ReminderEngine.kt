package `in`.medisafe.medisafe

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.util.AtomicFile
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit

private const val MINUTE = 60_000L
private const val CHANNEL = "medicine-reminders-v1"

internal object ReminderEngine {
    const val FIRE = "medisafe.reminder.FIRE"
    const val TAKE = "medisafe.reminder.TAKE"
    const val SKIP = "medisafe.reminder.SKIP"
    const val ID = "dose_id"

    private data class Dose(
        val id: String,
        val medicineId: String,
        val label: String,
        val quantity: String,
        val scheduled: Long,
    )

    private class Schedule(val data: JSONObject) {
        val id = data.getString("id")
        val start: LocalDate = LocalDate.parse(data.getString("startDate"))
        val interval = data.getLong("interval").coerceAtLeast(1)
        val frequency = data.getString("frequency")
        val weekdays = data.getJSONArray("weekdays").ints().toSet()
        val times = data.getJSONArray("times").objects().toList()
        val active = !data.optBoolean("paused") && !data.optBoolean("archived") &&
            frequency != "asNeeded" && times.isNotEmpty() &&
            (frequency != "weekly" || weekdays.isNotEmpty())
        private val end = data.getString("end")

        fun occursOn(day: LocalDate): Boolean {
            if (!active || day < start) return false
            val offset = ChronoUnit.DAYS.between(start, day)
            val weekday = day.dayOfWeek.value
            val startWeekday = start.dayOfWeek.value
            val count = if (frequency == "daily") {
                if (offset % interval != 0L) return false
                offset / interval + 1
            } else {
                val week = (offset + startWeekday - 1) / 7
                if (week % interval != 0L || weekday !in weekdays) return false
                if (week == 0L) {
                    weekdays.count { it in startWeekday..weekday }.toLong()
                } else {
                    (week / interval - 1) * weekdays.size +
                        weekdays.count { it >= startWeekday } + weekdays.count { it <= weekday }
                }
            }
            return when (end) {
                "date" -> day <= LocalDate.parse(data.getString("endDate"))
                "scheduledDays" -> count <= data.getLong("dayLimit")
                else -> true
            }
        }

        fun firstOnOrAfter(date: LocalDate): LocalDate? {
            if (!active) return null
            val day = maxOf(start, date)
            val offset = ChronoUnit.DAYS.between(start, day)
            val next = if (frequency == "daily") {
                day.plusDays((interval - offset % interval) % interval)
            } else {
                val weekday = day.dayOfWeek.value
                val week = (offset + start.dayOfWeek.value - 1) / 7
                val monday = day.minusDays(weekday.toLong() - 1)
                val current = if (week % interval == 0L) weekdays.filter { it >= weekday }.minOrNull() else null
                if (current != null) monday.plusDays(current.toLong() - 1) else {
                    monday.plusWeeks(interval - week % interval).plusDays(weekdays.min().toLong() - 1)
                }
            }
            return next.takeIf(::occursOn)
        }

        fun doses(day: LocalDate, zone: ZoneId): Sequence<Dose> = times.asSequence().map { time ->
            val minute = time.getInt("minutes")
            val name = data.getString("name")
            val strength = data.optString("strength")
            Dose(
                "$id/$day/$minute", id, if (strength.isBlank()) name else "$name · $strength",
                time.getString("quantity"),
                day.atTime(minute / 60, minute % 60).atZone(zone).toInstant().toEpochMilli(),
            )
        }
    }

    private class State(val json: JSONObject) {
        val config = json.optJSONObject("config") ?: JSONObject()
        val events = json.optJSONObject("events") ?: JSONObject().also { json.put("events", it) }
        val live = json.optJSONObject("live") ?: JSONObject().also { json.put("live", it) }
        val activated = json.optJSONObject("activated") ?: JSONObject().also { json.put("activated", it) }
        val alerts = (json.optJSONArray("alerts") ?: JSONArray()).ints()
        val snoozes = (json.optJSONArray("snoozes") ?: JSONArray()).ints()
        val grace = json.optInt("grace") * MINUTE
        val maxSnooze = json.optInt("maxSnooze") * MINUTE
        val finished = (config.optJSONArray("entries") ?: JSONArray()).objects()
            .map { it.getString("id") }.toHashSet()
        val schedules = (config.optJSONArray("medicines") ?: JSONArray()).objects().map(::Schedule).toList()

        fun terminal(id: String) = id in finished || events.has(id)
        fun dose(id: String): Dose? {
            val parts = id.split('/')
            if (parts.size != 3) return null
            val schedule = schedules.firstOrNull { it.id == parts[0] } ?: return null
            val day = runCatching { LocalDate.parse(parts[1]) }.getOrNull() ?: return null
            if (!schedule.occursOn(day)) return null
            return schedule.doses(day, ZoneId.systemDefault()).firstOrNull { it.id == id }
        }
    }

    private fun file(context: Context) = AtomicFile(File(context.filesDir, "medisafe-reminder-state.json"))

    private fun load(context: Context): JSONObject = try {
        JSONObject(String(file(context).readFully(), Charsets.UTF_8))
    } catch (_: FileNotFoundException) {
        JSONObject()
    }

    private fun save(context: Context, json: JSONObject) {
        val file = file(context)
        val stream = file.startWrite()
        try {
            stream.write(json.toString().toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }

    fun configure(context: Context, arguments: Map<*, *>) {
        val now = System.currentTimeMillis()
        val json = load(context)
        val previous = State(json)
        val config = JSONObject(arguments["snapshot"] as String)
        val reset = (arguments["resetAfter"] as? Number)?.toLong()
        val oldSchedules = previous.schedules.associateBy { it.id }
        val activated = JSONObject()
        val changed = mutableSetOf<String>()
        for (medicine in config.getJSONArray("medicines").objects()) {
            val schedule = Schedule(medicine)
            val old = oldSchedules[schedule.id]
            val sameTiming = old != null && listOf(
                "frequency", "interval", "weekdays", "times", "startDate", "end",
                "endDate", "dayLimit", "paused", "archived",
            ).all { key -> old.data.optString(key) == medicine.optString(key) }
            if (!sameTiming || reset != null) changed.add(schedule.id)
            activated.put(schedule.id, if (sameTiming && reset == null) {
                previous.activated.optLong(schedule.id, now)
            } else {
                reset ?: now
            })
        }
        json.put("config", config)
        json.put("activated", activated)
        for (key in listOf("alerts", "snoozes")) {
            json.put(key, JSONArray(arguments[key] as List<*>))
        }
        json.put("grace", arguments["grace"])
        json.put("maxSnooze", arguments["maxSnooze"])
        if (reset != null) json.put("events", JSONObject()).put("scan", now)
        val state = State(json)
        for (id in state.live.keys().asSequence().toList()) {
            if (id.substringBefore('/') in changed || state.terminal(id) || state.dose(id) == null) {
                state.live.remove(id)
                notifications(context).cancel(id, 0)
            }
        }
        save(context, json)
        reconcile(context)
    }

    fun events(context: Context): String = State(load(context)).events.let { events ->
        JSONArray(events.keys().asSequence().map { events.getJSONObject(it) }.toList()).toString()
    }

    fun acknowledge(context: Context, ids: List<*>) {
        val json = load(context)
        val events = State(json).events
        for (id in ids.filterIsInstance<String>()) events.remove(id)
        save(context, json)
    }

    fun snoozes(context: Context): Map<String, Long> = State(load(context)).live.let { live ->
        live.keys().asSequence().mapNotNull { id ->
            val until = live.optJSONObject(id)?.optLong("until", 0L) ?: 0L
            if (until > 0) id to until else null
        }.toMap()
    }

    private fun eligibleSnoozes(state: State, dose: Dose, now: Long): List<Int> {
        if (state.terminal(dose.id)) return emptyList()
        val live = state.live.optJSONObject(dose.id) ?: return emptyList()
        val origin = live.optLong("origin", dose.scheduled)
        val expiry = live.optLong("expiry", origin + state.alerts.last() * MINUTE + state.grace)
        if (now >= expiry) return emptyList()
        val minute = now / MINUTE * MINUTE
        return state.snoozes.filter { minute + it * MINUTE <= origin + state.maxSnooze }
    }

    fun choices(context: Context, id: String): List<Int> {
        val state = State(load(context))
        val dose = state.dose(id) ?: return emptyList()
        return eligibleSnoozes(state, dose, System.currentTimeMillis())
    }

    fun snooze(context: Context, id: String, minutes: Int): Boolean {
        val json = load(context)
        val state = State(json)
        val dose = state.dose(id) ?: return false
        val now = System.currentTimeMillis()
        if (minutes !in eligibleSnoozes(state, dose, now)) return false
        val live = state.live.getJSONObject(id)
        val until = now / MINUTE * MINUTE + minutes * MINUTE
        live.put("until", until).put("expiry", until + state.grace).put("snoozeAlert", false)
        save(context, json)
        notifications(context).cancel(id, 0)
        reconcile(context)
        return true
    }

    fun finish(context: Context, id: String, status: String) {
        val json = load(context)
        val state = State(json)
        val dose = state.dose(id) ?: return
        if (state.terminal(id)) return
        val live = state.live.optJSONObject(id) ?: return
        val now = System.currentTimeMillis()
        record(context, state, dose, status, now, live.optLong("origin", dose.scheduled))
        save(context, json)
        reconcile(context)
    }

    private fun record(context: Context, state: State, dose: Dose, status: String, now: Long, origin: Long) {
        val actual = Instant.ofEpochMilli(now).toString()
        state.events.put(dose.id, JSONObject().apply {
            put("id", dose.id)
            put("medicineId", dose.medicineId)
            put("label", dose.label)
            put("quantity", dose.quantity)
            put("status", status)
            put("recordedAt", actual)
            put("scheduledAt", Instant.ofEpochMilli(origin).toString())
            if (status == "taken") put("takenAt", actual)
        })
        state.live.remove(dose.id)
        notifications(context).cancel(dose.id, 0)
    }

    fun reconcile(context: Context) {
        val json = load(context)
        val state = State(json)
        if (state.alerts.isEmpty()) return
        val now = System.currentTimeMillis()
        val zone = ZoneId.systemDefault()
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val previous = Instant.ofEpochMilli(json.optLong("scan", now)).atZone(zone).toLocalDate()
        val from = maxOf(today.minusDays(366), minOf(previous, today).minusDays(1))
        var next = Long.MAX_VALUE
        fun consider(epoch: Long) {
            if (epoch > now && epoch < next) next = epoch
        }

        fun process(dose: Dose, activation: Long) {
            if (state.terminal(dose.id)) return
            val live = state.live.optJSONObject(dose.id)
            if (live == null && dose.scheduled < activation) return
            val origin = live?.optLong("origin", dose.scheduled) ?: dose.scheduled
            val snoozed = live?.optLong("until", 0L) ?: 0L
            val expiry = live?.optLong("expiry", origin + state.alerts.last() * MINUTE + state.grace)
                ?: (origin + state.alerts.last() * MINUTE + state.grace)
            if (now >= expiry) {
                record(context, state, dose, "missed", now, origin)
                return
            }
            if (snoozed > 0) {
                if (now >= snoozed && !live!!.optBoolean("snoozeAlert")) {
                    show(context, dose, origin)
                    live.put("snoozeAlert", true).put("expiry", now + state.grace)
                    consider(now + state.grace)
                } else {
                    consider(snoozed)
                    consider(expiry)
                }
                return
            }
            val due = state.alerts.indexOfLast { origin + it * MINUTE <= now }
            if (due > (live?.optInt("phase", -1) ?: -1)) {
                val entry = live ?: JSONObject().put("origin", origin)
                entry.put("phase", due)
                if (due == state.alerts.lastIndex) entry.put("expiry", now + state.grace)
                state.live.put(dose.id, entry)
                show(context, dose, origin)
                consider(entry.optLong("expiry", expiry))
            } else {
                consider(expiry)
            }
            for (minute in state.alerts) consider(origin + minute * MINUTE)
        }

        val processed = mutableSetOf<String>()
        for (schedule in state.schedules.filter { it.active }) {
            val activation = state.activated.optLong(schedule.id, now)
            val since = Instant.ofEpochMilli(activation).atZone(zone).toLocalDate()
            var day = schedule.firstOnOrAfter(maxOf(from, since))
            while (day != null && day <= today) {
                for (dose in schedule.doses(day, zone)) {
                    process(dose, activation)
                    processed.add(dose.id)
                }
                day = schedule.firstOnOrAfter(day.plusDays(1))
            }
            if (day != null) {
                for (dose in schedule.doses(day, zone)) consider(dose.scheduled)
            }
        }
        // An alert already shown keeps its original snooze and retry window during travel.
        for (id in state.live.keys().asSequence().toList()) {
            if (id in processed) continue
            val dose = state.dose(id)
            if (dose == null || state.terminal(id)) {
                state.live.remove(id)
                notifications(context).cancel(id, 0)
            } else {
                process(dose, 0L)
            }
        }
        json.put("scan", now)
        save(context, json)
        arm(context, next)
    }

    private fun arm(context: Context, whenAt: Long) {
        val manager = requireNotNull(context.getSystemService(AlarmManager::class.java))
        val pending = PendingIntent.getBroadcast(
            context, 0, Intent(context, ReminderReceiver::class.java).setAction(FIRE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        if (whenAt == Long.MAX_VALUE) {
            manager.cancel(pending)
        } else {
            try {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenAt, pending)
            } catch (_: SecurityException) {
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenAt, pending)
            }
        }
    }

    fun exact(context: Context): Boolean = Build.VERSION.SDK_INT < 31 ||
        requireNotNull(context.getSystemService(AlarmManager::class.java)).canScheduleExactAlarms()

    fun notifications(context: Context): NotificationManager =
        requireNotNull(context.getSystemService(NotificationManager::class.java))

    fun createChannel(context: Context) {
        val channel = NotificationChannel(CHANNEL, "Medicine reminders", NotificationManager.IMPORTANCE_HIGH)
        val audio = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build()
        val sound = Uri.parse("android.resource://${context.packageName}/raw/pill_rattle")
        channel.setSound(sound, audio)
        channel.enableVibration(true)
        channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        notifications(context).createNotificationChannel(channel)
    }

    fun canNotify(context: Context): Boolean {
        val manager = notifications(context)
        return manager.areNotificationsEnabled() &&
            manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun show(context: Context, dose: Dose, origin: Long) {
        createChannel(context)
        if (!canNotify(context)) return
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        fun broadcast(action: String): PendingIntent = PendingIntent.getBroadcast(
            context, 0, Intent(context, ReminderReceiver::class.java).setAction(action)
                .setData(Uri.parse("medisafe://dose/$action/${dose.id}")).putExtra(ID, dose.id), flags,
        )
        val snooze = PendingIntent.getActivity(context, 0,
            Intent(context, SnoozeActivity::class.java)
                .setData(Uri.parse("medisafe://snooze/${dose.id}")).putExtra(ID, dose.id), flags)
        val open = PendingIntent.getActivity(context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP), flags)
        val time = android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(origin))
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_reminder)
            .setContentTitle(dose.label)
            .setContentText("${dose.quantity} · Scheduled $time")
            .setStyle(Notification.BigTextStyle().bigText("${dose.quantity} · Scheduled $time"))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Taken", broadcast(TAKE)).build())
            .addAction(Notification.Action.Builder(null, "Snooze", snooze).build())
            .addAction(Notification.Action.Builder(null, "Skip", broadcast(SKIP)).build())
            .build()
        notifications(context).notify(dose.id, 0, notification)
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            when (intent.action) {
                ReminderEngine.TAKE -> intent.getStringExtra(ReminderEngine.ID)?.let {
                    ReminderEngine.finish(context, it, "taken")
                }
                ReminderEngine.SKIP -> intent.getStringExtra(ReminderEngine.ID)?.let {
                    ReminderEngine.finish(context, it, "skipped")
                }
                else -> ReminderEngine.reconcile(context)
            }
        } catch (error: Exception) {
            Log.e("Medisafe", "Could not update reminder delivery", error)
        }
    }
}

private fun JSONArray.ints(): List<Int> = (0 until length()).map(::getInt)
private fun JSONArray.objects(): Sequence<JSONObject> = (0 until length()).asSequence().map(::getJSONObject)
