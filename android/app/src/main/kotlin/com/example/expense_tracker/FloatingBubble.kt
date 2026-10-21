package com.example.expense_tracker

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import kotlin.math.hypot

/**
 * A "+" tab docked flush to the left or right edge of the screen: rounded on the
 * side facing the screen, flat where it meets the edge, so it looks attached to
 * it. Tap it to add an expense.
 *
 * Drag it and it turns into a round bubble that follows the finger; on release
 * it morphs back into a tab and slides into the nearest edge, and remembers
 * where it was left.
 */
class FloatingBubble(context: Context, private val onTap: () -> Unit) {
    private val ctx = context.applicationContext
    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val density = ctx.resources.displayMetrics.density
    private fun dp(v: Float) = v * density

    private val circle = dp(56f).toInt() // size while dragging
    private val tabW = dp(40f).toInt() // docked size
    private val tabH = dp(64f).toInt()
    private val tabInnerRadius = dp(20f) // rounding on the side facing the screen
    private val dockedAlpha = 0.92f
    private val slop = ViewConfiguration.get(ctx).scaledTouchSlop

    private var view: FrameLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var shape: GradientDrawable? = null
    private var anim: ValueAnimator? = null

    private var right = true // docked to the right edge?
    private var cy = 0 // vertical centre of the bubble, in px

    private fun screenW() = ctx.resources.displayMetrics.widthPixels
    private fun screenH() = ctx.resources.displayMetrics.heightPixels
    private fun lerp(a: Float, b: Float, t: Float) = a + (b - a) * t

    /**
     * Sets size, position and corner rounding for [t]: 0 = round bubble,
     * 1 = docked tab. [x] is the left edge; null means flush with the docked edge.
     */
    private fun fill(p: WindowManager.LayoutParams, d: GradientDrawable, t: Float, x: Int?) {
        val w = lerp(circle.toFloat(), tabW.toFloat(), t).toInt()
        val h = lerp(circle.toFloat(), tabH.toFloat(), t).toInt()
        p.width = w
        p.height = h
        p.x = x ?: if (right) screenW() - w else 0
        p.y = (cy - h / 2).coerceIn(0, (screenH() - h).coerceAtLeast(0))

        val inner = lerp(circle / 2f, tabInnerRadius, t) // side facing the screen
        val outer = lerp(circle / 2f, 0f, t) // side on the edge: flat when docked
        val l = if (right) inner else outer
        val r = if (right) outer else inner
        d.cornerRadii = floatArrayOf(l, l, r, r, r, r, l, l)
    }

    private fun relayout(t: Float, x: Int?) {
        val v = view ?: return
        val p = params ?: return
        val d = shape ?: return
        fill(p, d, t, x)
        try { wm.updateViewLayout(v, p) } catch (_: Exception) {}
    }

    fun show() {
        if (view != null) { reposition(); return }

        right = Prefs.bubbleRight(ctx)
        cy = Prefs.bubbleCy(ctx).takeIf { it >= 0 } ?: (screenH() * 0.4f).toInt()
        cy = cy.coerceIn(tabH / 2, (screenH() - tabH / 2).coerceAtLeast(tabH / 2))

        val d = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(0xFF14B8A6.toInt(), 0xFF0F766E.toInt())
        )
        shape = d

        val bubble = FrameLayout(ctx).apply {
            background = d
            elevation = dp(6f)
            alpha = dockedAlpha
            contentDescription = "Add expense"
            addView(
                ImageView(ctx).apply { setImageResource(R.drawable.ic_bubble_plus) },
                FrameLayout.LayoutParams(dp(26f).toInt(), dp(26f).toInt(), Gravity.CENTER)
            )
        }

        val type = if (Build.VERSION.SDK_INT >= 26)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val p = WindowManager.LayoutParams(
            tabW, tabH, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply { gravity = Gravity.TOP or Gravity.START }
        fill(p, d, 1f, null)
        params = p

        bubble.setOnTouchListener(object : View.OnTouchListener {
            var cx0 = 0
            var cy0 = 0
            var downX = 0f
            var downY = 0f
            var dragging = false

            override fun onTouch(v: View, e: MotionEvent): Boolean {
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        anim?.cancel()
                        cx0 = p.x + p.width / 2
                        cy0 = cy
                        downX = e.rawX
                        downY = e.rawY
                        dragging = false
                        v.alpha = 0.7f // pressed
                        return true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dx = e.rawX - downX
                        val dy = e.rawY - downY
                        if (!dragging && hypot(dx, dy) > slop) {
                            dragging = true
                            v.alpha = 1f
                        }
                        if (dragging) {
                            // Round bubble under the finger, kept on screen.
                            cy = (cy0 + dy).toInt()
                                .coerceIn(circle / 2, (screenH() - circle / 2).coerceAtLeast(circle / 2))
                            val x = (cx0 + dx - circle / 2f).toInt()
                                .coerceIn(0, (screenW() - circle).coerceAtLeast(0))
                            relayout(0f, x)
                        }
                        return true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        v.alpha = dockedAlpha
                        if (dragging) dock()
                        else if (e.actionMasked == MotionEvent.ACTION_UP) onTap()
                        return true
                    }
                }
                return false
            }
        })

        wm.addView(bubble, p)
        view = bubble
    }

    /** Morphs the bubble back into a tab and slides it into the nearest edge. */
    private fun dock() {
        val p = params ?: return
        right = p.x + p.width / 2 > screenW() / 2
        val startX = p.x
        anim?.cancel()
        anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 220
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                val t = it.animatedValue as Float
                val w = lerp(circle.toFloat(), tabW.toFloat(), t)
                val edgeX = if (right) screenW() - w else 0f
                relayout(t, lerp(startX.toFloat(), edgeX, t).toInt())
            }
            start()
        }
        Prefs.setBubblePos(ctx, right, cy)
    }

    /** Keeps it docked and on screen after a rotation or other size change. */
    fun reposition() {
        if (view == null) return
        right = Prefs.bubbleRight(ctx)
        cy = cy.coerceIn(tabH / 2, (screenH() - tabH / 2).coerceAtLeast(tabH / 2))
        relayout(1f, null)
    }

    fun remove() {
        anim?.cancel()
        val v = view ?: return
        view = null
        try { wm.removeView(v) } catch (_: Exception) {}
    }
}
