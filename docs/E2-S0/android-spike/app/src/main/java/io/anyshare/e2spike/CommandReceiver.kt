package io.anyshare.e2spike

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File

class CommandReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        appendLog(context, "command received action=${intent.action} extras=${intent.extras}")
        Log.i("E2SPIKE", "command received action=${intent.action}")
        val service = InjectAccessibilityService.instance
        if (service == null) {
            appendLog(context, "accessibility service not connected, command dropped")
            Log.i("E2SPIKE", "accessibility service not connected, command dropped")
            return
        }
        when (intent.action) {
            "io.anyshare.e2spike.TAP" -> service.tap(
                intent.getFloatExtra("x", 540f),
                intent.getFloatExtra("y", 1200f),
            )

            "io.anyshare.e2spike.SWIPE" -> service.swipe(
                intent.getFloatExtra("x1", 540f),
                intent.getFloatExtra("y1", 1800f),
                intent.getFloatExtra("x2", 540f),
                intent.getFloatExtra("y2", 600f),
                intent.getLongExtra("dur", 300),
            )

            "io.anyshare.e2spike.SCROLL2" -> service.twoFingerScroll(
                intent.getFloatExtra("cx", 540f),
                intent.getFloatExtra("cy", 1200f),
                intent.getFloatExtra("dy", 600f),
                intent.getLongExtra("dur", 300),
            )

            "io.anyshare.e2spike.LATENCY" -> service.latencyLoop(
                intent.getFloatExtra("x", 540f),
                intent.getFloatExtra("y", 1200f),
                intent.getIntExtra("count", 30),
            )

            "io.anyshare.e2spike.SETTEXT" -> service.setText(
                intent.getStringExtra("text") ?: "anyshare spike",
            )

            "io.anyshare.e2spike.CURSOR" -> CursorOverlay.move(
                context.applicationContext,
                intent.getFloatExtra("x", 540f),
                intent.getFloatExtra("y", 1200f),
            )

            "io.anyshare.e2spike.CURSOR_HIDE" -> CursorOverlay.hide(context.applicationContext)
        }
    }

    companion object {
        fun appendLog(context: Context, line: String) {
            try {
                val dir = context.getExternalFilesDir(null) ?: context.filesDir
                File(dir, "cmd.log").appendText("${System.currentTimeMillis()} $line\n")
            } catch (_: Exception) {
            }
        }
    }
}
