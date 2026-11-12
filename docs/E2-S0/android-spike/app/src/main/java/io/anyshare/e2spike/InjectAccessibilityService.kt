package io.anyshare.e2spike

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class InjectAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "E2SPIKE"
        @Volatile
        var instance: InjectAccessibilityService? = null
            private set
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onServiceConnected() {
        instance = this
        Log.i(TAG, "accessibility service connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onDestroy() {
        instance = null
        Log.i(TAG, "accessibility service destroyed")
        super.onDestroy()
    }

    fun tap(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        dispatchGestureLogged(
            "tap x=$x y=$y",
            GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, 40)).build(),
        )
    }

    fun doubleTap(x: Float, y: Float) {
        val path1 = Path().apply { moveTo(x, y) }
        val path2 = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path1, 0, 40))
            .addStroke(GestureDescription.StrokeDescription(path2, 100, 40))
            .build()
        dispatchGestureLogged("double-tap x=$x y=$y", gesture)
    }

    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long) {
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        dispatchGestureLogged(
            "swipe ($x1,$y1)->($x2,$y2) dur=$durationMs",
            GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, durationMs)).build(),
        )
    }

    fun twoFingerScroll(cx: Float, cy: Float, dy: Float, durationMs: Long) {
        val path1 = Path().apply {
            moveTo(cx - 200f, cy)
            lineTo(cx - 200f, cy - dy)
        }
        val path2 = Path().apply {
            moveTo(cx + 200f, cy)
            lineTo(cx + 200f, cy - dy)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path1, 0, durationMs))
            .addStroke(GestureDescription.StrokeDescription(path2, 0, durationMs))
            .build()
        dispatchGestureLogged("two-finger scroll dy=$dy dur=$durationMs", gesture)
    }

    fun latencyLoop(x: Float, y: Float, count: Int) {
        fun step(i: Int) {
            if (i > count) {
                Log.i(TAG, "latency loop done n=$count")
                return
            }
            val path = Path().apply { moveTo(x, y) }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 1))
                .build()
            val start = SystemClock.uptimeMillis()
            val accepted = dispatchGesture(
                gesture,
                object : GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription) {
                        log("latency #$i dt=${SystemClock.uptimeMillis() - start}ms ok=true")
                        mainHandler.postDelayed({ step(i + 1) }, 60)
                    }

                    override fun onCancelled(gestureDescription: GestureDescription) {
                        log("latency #$i dt=${SystemClock.uptimeMillis() - start}ms ok=false")
                        mainHandler.postDelayed({ step(i + 1) }, 60)
                    }
                },
                null,
            )
            if (!accepted) {
                log("latency #$i dispatch rejected")
                mainHandler.postDelayed({ step(i + 1) }, 60)
            }
        }
        step(1)
    }

    fun setText(text: String) {
        val root = rootInActiveWindow
        if (root == null) {
            Log.i(TAG, "set-text no active window")
            return
        }
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (focused == null) {
            Log.i(TAG, "set-text no focused input node")
            return
        }
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        val ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        Log.i(TAG, "set-text ok=$ok text=$text")
    }

    private fun log(line: String) {
        Log.i(TAG, line)
        CommandReceiver.appendLog(this, line)
    }

    private fun dispatchGestureLogged(tag: String, gesture: GestureDescription) {
        val start = SystemClock.uptimeMillis()
        val accepted = dispatchGesture(
            gesture,
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription) {
                    log("$tag completed dt=${SystemClock.uptimeMillis() - start}ms")
                }

                override fun onCancelled(gestureDescription: GestureDescription) {
                    log("$tag cancelled dt=${SystemClock.uptimeMillis() - start}ms")
                }
            },
            null,
        )
        log("$tag accepted=$accepted")
    }
}
