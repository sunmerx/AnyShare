package io.anyshare.e2spike

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.os.Build
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager

object CursorOverlay {

    private const val TAG = "E2SPIKE"
    private const val WINDOW_PX = 160

    private var view: CursorView? = null
    private var params: WindowManager.LayoutParams? = null

    private class CursorView(context: Context) : View(context) {

        private val arrowPath = Path().apply {
            moveTo(0f, 0f)
            lineTo(0f, 72f)
            lineTo(18f, 56f)
            lineTo(30f, 84f)
            lineTo(44f, 78f)
            lineTo(32f, 50f)
            lineTo(52f, 48f)
            close()
        }

        private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#40000000")
            style = Paint.Style.FILL
        }

        private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.FILL
        }

        private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#66000000")
            style = Paint.Style.STROKE
            strokeWidth = 3f
        }

        override fun onDraw(canvas: Canvas) {
            canvas.save()
            canvas.translate(3f, 3f)
            canvas.drawPath(arrowPath, shadowPaint)
            canvas.restore()
            canvas.drawPath(arrowPath, fillPaint)
            canvas.drawPath(arrowPath, strokePaint)
        }
    }

    fun move(context: Context, x: Float, y: Float) {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        var v = view
        var p = params
        if (v == null || p == null) {
            v = CursorView(context)
            p = WindowManager.LayoutParams(
                WINDOW_PX,
                WINDOW_PX,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                android.graphics.PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.LEFT
                if (Build.VERSION.SDK_INT >= 30) {
                    fitInsetsTypes = 0
                    fitInsetsSides = 0
                }
            }
            try {
                wm.addView(v, p)
                view = v
                params = p
                Log.i(TAG, "cursor overlay added")
            } catch (e: Exception) {
                Log.i(TAG, "cursor overlay add failed: ${e.message}")
                return
            }
        }
        p.x = x.toInt()
        p.y = y.toInt()
        wm.updateViewLayout(v, p)
        Log.i(TAG, "cursor moved to x=$x y=$y")
    }

    fun hide(context: Context) {
        val v = view ?: return
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        try {
            wm.removeView(v)
        } catch (e: Exception) {
            Log.i(TAG, "cursor overlay remove failed: ${e.message}")
        }
        view = null
        params = null
        Log.i(TAG, "cursor overlay hidden")
    }
}
