package com.example.expense_tracker

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

/**
 * Two-step overlay: "What was it for?" then "How much was it?".
 * Always dismissible: Cancel button, tap outside the card, or the back key.
 * The keyboard opens by itself, and switches to a number pad on step 2.
 *
 * With [preview] set nothing is saved (used by the "Preview the popup" button).
 */
class ExpensePopup(
    context: Context,
    /** The app that was closed, or null for a quick add from the floating button. */
    private val appLabel: String?,
    private val appPackage: String? = null,
    private val preview: Boolean = false,
) {
    private val ctx = context.applicationContext
    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val imm = ctx.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
    private val main = Handler(Looper.getMainLooper())

    private class Palette(
        val card: Int, val text: Int, val sub: Int, val field: Int,
        val hint: Int, val primary: Int, val onPrimary: Int, val pill: Int, val error: Int,
    )

    private val night = (ctx.resources.configuration.uiMode and
        Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private val pal = if (night)
        Palette(0xFF1F2933.toInt(), 0xFFF3F4F6.toInt(), 0xFF9CA3AF.toInt(), 0xFF2B3743.toInt(),
            0xFF6B7280.toInt(), 0xFF2DD4BF.toInt(), 0xFF042F2E.toInt(), 0xFF2B3743.toInt(), 0xFFF87171.toInt())
    else
        Palette(0xFFFFFFFF.toInt(), 0xFF111827.toInt(), 0xFF6B7280.toInt(), 0xFFF3F4F6.toInt(),
            0xFF9CA3AF.toInt(), 0xFF0F766E.toInt(), 0xFFFFFFFF.toInt(), 0xFFE5E7EB.toInt(), 0xFFDC2626.toInt())

    private var root: FrameLayout? = null
    private lateinit var stepPill: TextView
    private lateinit var heading: TextView
    private lateinit var contextPill: TextView
    private lateinit var prefix: TextView
    private lateinit var edit: EditText
    private lateinit var errorText: TextView
    private lateinit var back: TextView
    private lateinit var primary: TextView

    private var step = 0
    private var title = ""

    val isShowing get() = root != null

    private fun dp(v: Int) = (v * ctx.resources.displayMetrics.density).toInt()

    private fun rounded(color: Int, radiusDp: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radiusDp).toFloat()
    }

    private fun text(
        value: String, sizeSp: Float, color: Int, bold: Boolean = false
    ) = TextView(ctx).apply {
        text = value
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun button(label: String, color: Int, bg: Int?, onClick: () -> Unit) =
        text(label, 15f, color, bold = true).apply {
            gravity = Gravity.CENTER
            setPadding(dp(20), dp(12), dp(20), dp(12))
            if (bg != null) background = rounded(bg, 14)
            setOnClickListener { onClick() }
        }

    fun show() {
        if (root != null) return

        val frame = object : FrameLayout(ctx) {
            override fun dispatchKeyEvent(e: KeyEvent): Boolean {
                if (e.keyCode == KeyEvent.KEYCODE_BACK) {
                    if (e.action == KeyEvent.ACTION_UP) dismiss()
                    return true
                }
                return super.dispatchKeyEvent(e)
            }
        }
        frame.setBackgroundColor(0xA6000000.toInt())
        frame.setOnClickListener { dismiss() } // tap outside the card

        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(18), dp(20), dp(14))
            background = rounded(pal.card, 24)
            elevation = dp(12).toFloat()
            isClickable = true // swallow taps so they don't dismiss
        }

        // ---- header: app icon, title, "After using X", step counter
        val icon = ImageView(ctx).apply {
            val d = try {
                appPackage?.let { ctx.packageManager.getApplicationIcon(it) }
            } catch (_: Exception) {
                null
            }
            if (d != null) {
                setImageDrawable(d)
                background = rounded(pal.pill, 12)
                clipToOutline = true
                outlineProvider = ViewOutlineProvider.BACKGROUND
            } else {
                visibility = View.GONE
            }
        }
        val titles = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(text("Log an expense", 15f, pal.text, bold = true))
            addView(text(
                when {
                    preview -> "Preview, nothing is saved"
                    appLabel != null -> "After using $appLabel"
                    else -> "Quick add"
                },
                13f, pal.sub))
        }
        stepPill = text("1 of 2", 12f, pal.sub, bold = true).apply {
            background = rounded(pal.pill, 12)
            setPadding(dp(10), dp(4), dp(10), dp(4))
        }
        val header = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(icon, LinearLayout.LayoutParams(dp(40), dp(40)).apply { marginEnd = dp(12) })
            addView(titles, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(stepPill)
        }

        // ---- question, optional "back to name" pill, input field
        heading = text("", 22f, pal.text, bold = true).apply { setPadding(0, dp(18), 0, dp(10)) }
        contextPill = text("", 13f, pal.text, bold = true).apply {
            background = rounded(pal.pill, 12)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            setOnClickListener { goBack() }
        }
        prefix = text("₹", 22f, pal.primary, bold = true).apply { setPadding(0, 0, dp(6), 0) }
        edit = EditText(ctx).apply {
            background = null
            setTextColor(pal.text)
            setHintTextColor(pal.hint)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setPadding(dp(4), dp(14), dp(4), dp(14))
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_NEXT || actionId == EditorInfo.IME_ACTION_DONE) {
                    submit(); true
                } else false
            }
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) { errorText.visibility = View.GONE }
                override fun beforeTextChanged(s: CharSequence?, st: Int, c: Int, a: Int) {}
                override fun onTextChanged(s: CharSequence?, st: Int, b: Int, c: Int) {}
            })
        }
        val field = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(pal.field, 16)
            setPadding(dp(16), 0, dp(16), 0)
            addView(prefix)
            addView(edit, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        errorText = text("", 13f, pal.error).apply {
            visibility = View.GONE
            setPadding(dp(4), dp(6), 0, 0)
        }

        // ---- buttons
        val cancel = button("Cancel", pal.sub, null) { dismiss() }
        back = button("Back", pal.text, null) { goBack() }
        primary = button("Next", pal.onPrimary, pal.primary) { submit() }
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(14), 0, 0)
            addView(cancel)
            addView(View(ctx), LinearLayout.LayoutParams(0, 1, 1f))
            addView(back)
            addView(primary)
        }

        card.addView(header)
        card.addView(heading)
        card.addView(contextPill, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { bottomMargin = dp(10) })
        card.addView(field)
        card.addView(errorText)
        card.addView(row)

        frame.addView(card, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL
        ).apply {
            // Upper part of the screen so the keyboard never covers the card.
            topMargin = (ctx.resources.displayMetrics.heightPixels * 0.12f).toInt()
            marginStart = dp(20)
            marginEnd = dp(20)
        })

        render()

        val type = if (Build.VERSION.SDK_INT >= 26)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        // No FLAG_NOT_FOCUSABLE: the field must be focusable to get the keyboard.
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            type,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )
        lp.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or
            WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE

        // Slide-and-fade in.
        frame.alpha = 0f
        card.translationY = dp(28).toFloat()
        wm.addView(frame, lp)
        root = frame
        frame.animate().alpha(1f).setDuration(180).start()
        card.animate().translationY(0f).setDuration(220).start()

        // Open the keyboard as soon as the window can take input.
        frame.viewTreeObserver.addOnWindowFocusChangeListener(
            object : android.view.ViewTreeObserver.OnWindowFocusChangeListener {
                override fun onWindowFocusChanged(hasFocus: Boolean) {
                    if (hasFocus) {
                        showKeyboard()
                        if (frame.viewTreeObserver.isAlive)
                            frame.viewTreeObserver.removeOnWindowFocusChangeListener(this)
                    }
                }
            })
        showKeyboard()
    }

    /**
     * Asks for the keyboard, and keeps asking for a moment: right after the
     * window is added the system often isn't ready and silently ignores it.
     */
    private fun showKeyboard(attempt: Int = 0) {
        if (root == null) return
        edit.requestFocus()
        val shown = imm.showSoftInput(edit, 0)
        if (!shown && attempt < 6) {
            main.postDelayed({ showKeyboard(attempt + 1) }, 120)
        }
    }

    private fun render(initial: String = "") {
        errorText.visibility = View.GONE
        edit.setText(initial)
        edit.setSelection(edit.text.length)
        if (step == 0) {
            stepPill.text = "1 of 2"
            heading.text = "What was it for?"
            edit.hint = "e.g. Lunch"
            edit.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            edit.imeOptions = EditorInfo.IME_ACTION_NEXT
            prefix.visibility = View.GONE
            contextPill.visibility = View.GONE
            back.visibility = View.GONE
            primary.text = "Next"
        } else {
            stepPill.text = "2 of 2"
            heading.text = "How much was it?"
            edit.hint = "0"
            edit.inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
            edit.imeOptions = EditorInfo.IME_ACTION_DONE
            prefix.visibility = View.VISIBLE
            contextPill.text = "✎  $title"
            contextPill.visibility = View.VISIBLE
            back.visibility = View.VISIBLE
            primary.text = "Save"
        }
        imm.restartInput(edit) // pick up the new keyboard type (text -> number pad)
        edit.post { showKeyboard() }
    }

    private fun goBack() {
        if (step == 0) return
        step = 0
        render(title)
    }

    private fun fail(message: String) {
        errorText.text = message
        errorText.visibility = View.VISIBLE
    }

    private fun submit() {
        val value = edit.text.toString().trim()
        if (step == 0) {
            if (value.isEmpty()) return fail("Enter what the expense was for")
            title = value
            step = 1
            render()
        } else {
            val amount = value.toDoubleOrNull()
            if (amount == null || amount <= 0) return fail("Enter a valid amount")
            val t = title
            dismiss()
            if (preview) {
                Toast.makeText(ctx, "Preview only, nothing was saved", Toast.LENGTH_SHORT).show()
                return
            }
            Thread {
                try {
                    // From an app: its name is the mode. Quick add: the default, "Direct".
                    val uploaded = ExpenseStore.save(
                        ctx, t, amount, "Other",
                        if (appLabel != null) "After using $appLabel" else "",
                        appLabel ?: "Direct"
                    )
                    main.post {
                        Toast.makeText(
                            ctx,
                            when {
                                uploaded -> "Saved and uploaded to Notion"
                                !Prefs.autoSync(ctx) -> "Saved on device"
                                else -> "Saved on device, push it from the app later"
                            },
                            Toast.LENGTH_SHORT
                        ).show()
                    }
                } catch (e: Exception) {
                    main.post { Toast.makeText(ctx, "Couldn't save expense", Toast.LENGTH_LONG).show() }
                }
            }.start()
        }
    }

    fun dismiss() {
        val r = root ?: return
        root = null
        imm.hideSoftInputFromWindow(r.windowToken, 0)
        try { wm.removeView(r) } catch (_: Exception) {}
    }
}
