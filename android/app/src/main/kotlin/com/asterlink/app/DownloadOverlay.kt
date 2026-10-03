package com.asterlink.app

import android.app.Activity
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.RippleDrawable
import android.graphics.ColorFilter
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

internal data class OverlayBounds(val x: Int, val y: Int, val width: Int, val height: Int) {
    fun fit(screenWidth: Int, screenHeight: Int, minWidth: Int, minHeight: Int): OverlayBounds {
        val w = width.coerceIn(minWidth.coerceAtMost(screenWidth), screenWidth)
        val h = height.coerceIn(minHeight.coerceAtMost(screenHeight), screenHeight)
        return OverlayBounds(x.coerceIn(0, screenWidth - w), y.coerceIn(0, screenHeight - h), w, h)
    }
}

/** Application-owned view; the existing retained engine remains the sole download coordinator. */
class DownloadOverlay(
    private val app: Context,
    private val activity: () -> Activity?,
    private val command: (String, String?, (Boolean) -> Unit) -> Unit,
    private val changed: (Map<String, Any>) -> Unit,
    private val report: (String, Throwable) -> Unit = { _, _ -> },
    private val permission: () -> Boolean = { Settings.canDrawOverlays(app) }
) : ComponentCallbacks {
    companion object { const val OPEN_DOWNLOADS = "com.asterlink.app.OPEN_DOWNLOADS" }
    private val context: Context = if (Build.VERSION.SDK_INT >= 30) {
        app.createDisplayContext(app.getSystemService(android.hardware.display.DisplayManager::class.java)
            .getDisplay(android.view.Display.DEFAULT_DISPLAY))
            .createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
    } else app
    private val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val preferences = app.getSharedPreferences("download_overlay", Context.MODE_PRIVATE)
    private var snapshot: Map<*, *> = emptyMap<Any, Any>()
    private var root: View? = null
    private var params: WindowManager.LayoutParams? = null
    private var panelBounds = OverlayBounds(dp(preferences.getInt("panelX", 16)), dp(preferences.getInt("panelY", 100)),
        dp(preferences.getInt("width", 320)), dp(preferences.getInt("height", 480)))
    private var bubbleBounds = OverlayBounds(dp(preferences.getInt("bubbleX", 0)), dp(preferences.getInt("bubbleY", 160)), dp(76), dp(88))
    var collapsed = false
        private set
    var pendingPermission = false
        private set
    val visible get() = root != null
    internal val contentView get() = root
    internal val currentBounds get() = if (collapsed) bubbleBounds else panelBounds
    private var subscribed = false
    private var summary: TextView? = null
    private var percentage: TextView? = null
    private var transferSpeed: TextView? = null
    private var transferred: TextView? = null
    private var overall: ProgressBar? = null
    private var rows: LinearLayout? = null
    private var bubble: ProgressBall? = null
    private val taskRows = linkedMapOf<String, TaskRow>()
    private var rowsBound = false
    private var compactPanel = false
    private var adaptPanel: ((Int, Int) -> Unit)? = null
    private var busy = false
    private val dark get() = snapshot["dark"] == true
    private val foreground get() = if (dark) Color.rgb(242, 242, 247) else Color.rgb(28, 28, 30)
    private val muted get() = if (dark) Color.rgb(174, 174, 178) else Color.rgb(108, 108, 112)
    private val background get() = if (dark) Color.rgb(28, 28, 30) else Color.rgb(242, 242, 247)
    private val surface get() = if (dark) Color.rgb(44, 44, 46) else Color.WHITE
    private val accent get() = if (dark) Color.rgb(100, 181, 255) else Color.rgb(0, 104, 224)
    private val primary get() = Color.rgb(0, 112, 238)
    private val destructive get() = Color.rgb(217, 45, 32)
    private val softAccent get() = if (dark) Color.rgb(32, 53, 76) else Color.rgb(229, 240, 255)
    private val success get() = if (dark) Color.rgb(48, 209, 88) else Color.rgb(36, 138, 61)
    private val failure get() = if (dark) Color.rgb(255, 159, 10) else Color.rgb(180, 83, 9)

    private fun dp(value: Int) = (value * context.resources.displayMetrics.density + .5f).toInt()
    private fun number(key: String) = (snapshot[key] as? Number)?.toLong() ?: 0L
    fun state(): Map<String, Any> = mapOf("visible" to visible, "collapsed" to collapsed, "pendingPermission" to pendingPermission)

    fun show(value: Map<*, *>): Map<String, Any> {
        snapshot = value
        if (!permission()) {
            val current = activity() ?: throw IllegalStateException("请返回应用开启悬浮窗")
            pendingPermission = true
            try {
                current.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${app.packageName}")))
            } catch (error: Exception) {
                pendingPermission = false
                throw error
            }
            return state()
        }
        pendingPermission = false
        collapsed = false
        render()
        return state()
    }

    fun resumed() {
        if (pendingPermission) {
            pendingPermission = false
            if (permission()) {
                try { render() } catch (error: Exception) { fail(error) }
            } else {
                Toast.makeText(app, "未授予悬浮窗权限，可在下载管理中重新开启", Toast.LENGTH_LONG).show()
            }
            changed(state())
        } else if (visible && !permission()) close()
    }

    fun update(value: Map<*, *>) {
        val previousDark = dark
        snapshot = value
        if (!visible) return
        if (!permission()) { close(); return }
        try {
            if (previousDark != dark) render() else bind()
        } catch (error: Exception) { fail(error) }
    }

    fun close() {
        pendingPermission = false
        saveBounds()
        removeView()
        if (subscribed) { app.unregisterComponentCallbacks(this); subscribed = false }
        changed(state())
    }

    private fun removeView() {
        root?.let { try { wm.removeViewImmediate(it) } catch (_: IllegalArgumentException) { } }
        root = null
        params = null
        summary = null
        percentage = null
        transferSpeed = null
        transferred = null
        overall = null
        rows = null
        bubble = null
        adaptPanel = null
        taskRows.clear()
        rowsBound = false
    }

    private fun fail(error: Exception) {
        report("download.overlay_failed", error)
        close()
        Toast.makeText(app, "悬浮窗已关闭，请检查悬浮窗权限后重新开启", Toast.LENGTH_LONG).show()
    }

    private fun screen(): Pair<Int, Int> {
        if (Build.VERSION.SDK_INT >= 30) {
            val metrics = wm.currentWindowMetrics
            val inset = metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            return max(1, metrics.bounds.width() - inset.left - inset.right) to max(1, metrics.bounds.height() - inset.top - inset.bottom)
        }
        val metrics = context.resources.displayMetrics
        return metrics.widthPixels to max(1, metrics.heightPixels - dp(48))
    }

    private fun fitted(bounds: OverlayBounds): OverlayBounds {
        val (w, h) = screen()
        return bounds.fit(w, h, dp(if (collapsed) 76 else 200), dp(if (collapsed) 88 else 180))
    }

    private fun render() {
        removeView()
        val bounds = fitted(if (collapsed) bubbleBounds else panelBounds)
        if (collapsed) bubbleBounds = bounds else panelBounds = bounds
        val view = if (collapsed) ball() else panel()
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else {
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        }
        val layout = WindowManager.LayoutParams(bounds.width, bounds.height, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.LEFT
            x = bounds.x; y = bounds.y
            if (Build.VERSION.SDK_INT >= 28) layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_NEVER
            title = "文析助手下载悬浮窗"
        }
        wm.addView(view, layout)
        root = view
        params = layout
        if (!subscribed) { app.registerComponentCallbacks(this); subscribed = true }
        bind()
        changed(state())
    }

    private fun shape(radius: Int, color: Int = surface, bordered: Boolean = false) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(radius).toFloat()
        if (bordered) setStroke(dp(1), if (dark) Color.rgb(64, 64, 67) else Color.rgb(224, 225, 232))
    }

    private fun text(label: String, size: Float = 13f) = TextView(context).apply {
        this.text = label; textSize = size; setTextColor(this@DownloadOverlay.foreground)
        maxLines = 1; ellipsize = TextUtils.TruncateAt.END
        gravity = Gravity.CENTER_VERTICAL
    }

    private fun button(label: String, description: String = label, action: () -> Unit) = text(label, 12f).apply {
        gravity = Gravity.CENTER
        contentDescription = description
        isClickable = true; isFocusable = true
        minWidth = dp(44); minHeight = dp(44)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        background = RippleDrawable(ColorStateList.valueOf(if (dark) 0x33FFFFFF else 0x18007AFF), shape(14, softAccent), null)
        setTextColor(accent)
        setOnClickListener { try { action() } catch (error: Exception) { fail(error) } }
    }

    private fun bar() = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
        max = 100
        progressTintList = ColorStateList.valueOf(accent)
        progressBackgroundTintList = ColorStateList.valueOf(if (dark) Color.DKGRAY else Color.rgb(233, 233, 238))
        indeterminateTintList = ColorStateList.valueOf(accent)
        minimumHeight = 0
    }

    private fun panel(): View {
        val frame = FrameLayout(context).apply {
            background = shape(28, this@DownloadOverlay.background, bordered = true); clipToOutline = true
            elevation = dp(8).toFloat()
        }
        val column = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(12), dp(6), dp(12), dp(14)) }
        frame.addView(column, FrameLayout.LayoutParams(-1, -1))
        val grip = FrameLayout(context).apply { contentDescription = "拖动移动下载悬浮窗" }
        grip.addView(View(context).apply { background = shape(2, if (dark) 0xFF636366.toInt() else 0xFFC7C7CC.toInt()) },
            FrameLayout.LayoutParams(dp(32), dp(4), Gravity.TOP or Gravity.CENTER_HORIZONTAL))
        drag(grip)
        column.addView(grip, LinearLayout.LayoutParams(-1, dp(6)))
        val title = text("下载管理", 15f).apply {
            tag = "download-overlay-title"
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
            contentDescription = "打开下载管理"
            isFocusable = true
            setOnClickListener { try { send("openDownloads") } catch (error: Exception) { fail(error) } }
        }
        drag(title)
        column.addView(title, LinearLayout.LayoutParams(-1, dp(32)))
        val overview = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; background = shape(16)
            setPadding(dp(10), dp(7), dp(10), dp(7))
        }
        val metrics = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
        summary = text("", 12f).also { metrics.addView(it, LinearLayout.LayoutParams(0, -2, 1f)) }
        percentage = text("", 18f).apply {
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }.also { metrics.addView(it, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = dp(6) }) }
        overview.addView(metrics, LinearLayout.LayoutParams(-1, -2))
        val amounts = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
        transferSpeed = text("", 11f).apply { setTextColor(accent) }.also { amounts.addView(it, LinearLayout.LayoutParams(0, -2, 1f)) }
        transferred = text("", 10f).apply { setTextColor(muted); gravity = Gravity.RIGHT or Gravity.CENTER_VERTICAL }.also {
            amounts.addView(it, LinearLayout.LayoutParams(0, -2, 1.6f))
        }
        overview.addView(amounts, LinearLayout.LayoutParams(-1, -2))
        overall = bar().also { overview.addView(it, LinearLayout.LayoutParams(-1, dp(3)).apply { topMargin = dp(5) }) }
        column.addView(overview, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4); bottomMargin = dp(6) })
        val scroll = ScrollView(context).apply {
            tag = "download-task-list"
            isFillViewport = false; isVerticalScrollBarEnabled = true
        }
        rows = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        scroll.addView(rows, FrameLayout.LayoutParams(-1, -2))
        column.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
        val footer = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
        val collapse = button("收起为悬浮球") { collapsed = true; render() }.apply {
            textSize = 12f; minHeight = dp(36); setTextColor(Color.WHITE)
            background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), shape(18, primary), null)
            setPadding(dp(10), 0, dp(10), 0)
            setCompoundDrawablesRelative(Glyph("collapse", Color.WHITE).apply { setBounds(0, 0, dp(18), dp(18)) }, null, null, null)
            compoundDrawablePadding = dp(4)
        }
        footer.addView(collapse, LinearLayout.LayoutParams(-2, dp(36)))
        footer.addView(View(context), LinearLayout.LayoutParams(0, 1, 1f))
        footer.addView(button("关闭", "关闭悬浮窗，继续下载") { close() }.apply {
            textSize = 12f; minHeight = dp(36); setTextColor(Color.WHITE)
            background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), shape(18, destructive), null)
            setPadding(dp(10), 0, dp(10), 0)
        }, LinearLayout.LayoutParams(-2, dp(36)).apply { leftMargin = dp(4) })
        val handle = button("", "拖动调整小窗大小") { }.apply {
            minWidth = dp(32); minHeight = dp(32)
            background = RippleDrawable(ColorStateList.valueOf(0x18007AFF), shape(10), null)
            setCompoundDrawables(Glyph("resize", muted).apply { setBounds(0, 0, dp(18), dp(18)) }, null, null, null)
            setPadding(dp(7), dp(7), dp(7), dp(7))
        }
        drag(handle, DragOperation.RESIZE)
        footer.addView(handle, LinearLayout.LayoutParams(dp(32), dp(32)).apply { leftMargin = dp(4) })
        column.addView(footer, LinearLayout.LayoutParams(-1, dp(36)).apply { topMargin = dp(4) })

        val widthHandle = FrameLayout(context).apply {
            contentDescription = "左右拖动调整小窗宽度"
            addView(View(context).apply { background = shape(2, muted) },
                FrameLayout.LayoutParams(dp(3), dp(22), Gravity.CENTER))
        }
        drag(widthHandle, DragOperation.WIDTH)
        frame.addView(widthHandle, FrameLayout.LayoutParams(dp(12), dp(64), Gravity.RIGHT or Gravity.CENTER_VERTICAL))
        val heightHandle = FrameLayout(context).apply {
            contentDescription = "上下拖动调整小窗高度"
            addView(View(context).apply { background = shape(2, muted) },
                FrameLayout.LayoutParams(dp(24), dp(3), Gravity.CENTER))
        }
        drag(heightHandle, DragOperation.HEIGHT)
        frame.addView(heightHandle, FrameLayout.LayoutParams(dp(64), dp(12), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL))

        var previousCompact: Boolean? = null
        var previousNarrow: Boolean? = null
        fun adapt(width: Int, height: Int) {
            val compact = height < dp(280)
            val narrow = width < dp(280) || width < dp(320) && context.resources.configuration.fontScale > 1.2f
            if (previousCompact != compact) {
                previousCompact = compact
                compactPanel = compact
                amounts.visibility = if (compact) View.GONE else View.VISIBLE
                overall?.visibility = if (compact) View.GONE else View.VISIBLE
                overview.setPadding(dp(10), dp(if (compact) 3 else 7), dp(10), dp(if (compact) 3 else 7))
                title.layoutParams = title.layoutParams.apply { this.height = dp(if (compact) 28 else 32) }
                percentage?.textSize = if (compact) 14f else 18f
                taskRows.values.forEach { it.compact(compact) }
            }
            if (previousNarrow != narrow) {
                previousNarrow = narrow
                collapse.text = if (narrow) "收起" else "收起为悬浮球"
            }
        }
        adaptPanel = ::adapt
        adapt(panelBounds.width, panelBounds.height)
        frame.addOnLayoutChangeListener { _, left, top, right, bottom, _, _, _, _ -> adapt(right - left, bottom - top) }
        return frame
    }

    private inner class Glyph(private val kind: String, color: Int) : Drawable() {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color; style = Paint.Style.STROKE; strokeWidth = 1.7f
            strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
        }
        override fun draw(canvas: Canvas) {
            canvas.save(); canvas.translate(bounds.left.toFloat(), bounds.top.toFloat())
            canvas.scale(bounds.width() / 24f, bounds.height() / 24f)
            if (kind == "collapse") {
                canvas.drawRoundRect(2f, 3f, 17f, 18f, 3f, 3f, paint)
                canvas.drawLine(6f, 7f, 11f, 12f, paint)
                canvas.drawLine(7f, 12f, 11f, 12f, paint)
                canvas.drawLine(11f, 8f, 11f, 12f, paint)
                paint.style = Paint.Style.FILL
                canvas.drawCircle(19f, 19f, 4f, paint)
                paint.style = Paint.Style.STROKE
            } else {
                canvas.drawLine(5f, 18f, 18f, 5f, paint)
                canvas.drawLine(11f, 18f, 18f, 11f, paint)
                canvas.drawLine(17f, 18f, 18f, 17f, paint)
            }
            canvas.restore()
        }
        override fun setAlpha(alpha: Int) { paint.alpha = alpha }
        override fun setColorFilter(colorFilter: ColorFilter?) { paint.colorFilter = colorFilter }
        @Suppress("OVERRIDE_DEPRECATION") override fun getOpacity() = PixelFormat.TRANSLUCENT
    }

    private fun ball(): View = ProgressBall(context).also {
        bubble = it
        it.setOnClickListener { try { collapsed = false; render() } catch (error: Exception) { fail(error) } }
        drag(it)
    }

    private fun bind() {
        if (collapsed) { bubble?.refresh(); return }
        val status = snapshot["status"] as? String ?: "暂无任务"
        val speed = bytes(number("speed")) + "/s"
        val percent = (snapshot["progress"] as? Number)?.toInt() ?: -1
        val complete = number("count") > 0 && number("completed") == number("count")
        val tint = if (complete) success else if (number("active") == 0L && number("failed") > 0) failure else accent
        summary?.text = "$status · ${number("count")} 项"
        percentage?.text = if (percent >= 0) "$percent%" else "—"
        percentage?.setTextColor(tint)
        transferSpeed?.text = if (number("active") > 0) speed else "${number("completed")}/${number("count")} 已完成"
        transferSpeed?.setTextColor(tint)
        transferred?.text = if (number("total") > 0) "${bytes(number("downloaded"))} / ${bytes(number("total"))}" else "已下载 ${bytes(number("downloaded"))}"
        overall?.isIndeterminate = percent < 0 && number("active") > 0
        overall?.progress = percent.coerceIn(0, 100)
        overall?.progressTintList = ColorStateList.valueOf(tint)
        val data = (snapshot["tasks"] as? List<*>)?.filterIsInstance<Map<*, *>>()?.take(20).orEmpty()
        val ids = data.map { it["id"] as? String ?: "" }
        if (!rowsBound || ids != taskRows.keys.toList()) {
            rowsBound = true
            rows?.removeAllViews(); taskRows.clear()
            for ((index, entry) in data.withIndex()) {
                val row = TaskRow()
                taskRows[ids[index]] = row
                rows?.addView(row.view, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(5) })
            }
            if (data.isEmpty()) rows?.addView(text("添加下载任务后，即可在这里查看进度", 12f).apply {
                setTextColor(muted); maxLines = 2; gravity = Gravity.CENTER
                background = shape(16); setPadding(dp(12), dp(12), dp(12), dp(12))
            }, LinearLayout.LayoutParams(-1, -2))
            if (number("count") > data.size) rows?.addView(text("更多任务请打开下载列表查看", 11f).apply { setTextColor(muted) })
        }
        for (entry in data) taskRows[entry["id"]]?.bind(entry)
    }

    private inner class TaskRow {
        val view = LinearLayout(context).apply {
            tag = "download-task-row"
            gravity = Gravity.CENTER_VERTICAL; background = shape(14)
            setPadding(dp(10), dp(5), dp(8), dp(5))
        }
        private val title = text("", 13f).apply { typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL) }
        private val info = text("", 10f).apply { setTextColor(muted) }
        private val status = text("", 10f).apply { setTextColor(muted) }
        private val speedLabel = text("", 10f).apply { setTextColor(accent); gravity = Gravity.RIGHT or Gravity.CENTER_VERTICAL }
        private val progress = bar()
        private var action = ""
        private var id = ""
        private val control = button("", "操作下载任务") { if (action.isNotEmpty()) send(action, id) }
        init {
            val labels = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
            labels.addView(title); labels.addView(info)
            val details = LinearLayout(context)
            details.addView(status, LinearLayout.LayoutParams(0, -2, 1f))
            details.addView(speedLabel, LinearLayout.LayoutParams(-2, -2))
            labels.addView(details, LinearLayout.LayoutParams(-1, -2))
            labels.addView(progress, LinearLayout.LayoutParams(-1, dp(3)).apply { topMargin = dp(4) })
            view.addView(labels, LinearLayout.LayoutParams(0, -2, 1f))
            view.addView(control, LinearLayout.LayoutParams(dp(44), dp(44)).apply { leftMargin = dp(8) })
            compact(compactPanel)
        }
        fun compact(value: Boolean) {
            info.visibility = if (value) View.GONE else View.VISIBLE
            control.minHeight = dp(if (value) 32 else 44)
            control.layoutParams = control.layoutParams.apply { height = dp(if (value) 32 else 44) }
        }
        fun bind(data: Map<*, *>) {
            id = data["id"] as? String ?: ""
            action = data["action"] as? String ?: ""
            title.text = data["name"] as? String ?: "下载任务"
            val received = (data["downloaded"] as? Number)?.toLong() ?: 0
            val total = (data["total"] as? Number)?.toLong() ?: 0
            val speed = (data["speed"] as? Number)?.toLong() ?: 0
            val value = (data["progress"] as? Number)?.toInt() ?: -1
            info.text = "${bytes(received)}${if (total > 0) " / ${bytes(total)}" else ""}${if (value >= 0) " · $value%" else ""}"
            status.text = "${data["label"] ?: ""}"
            status.setTextColor(if (data["status"] == "failed") failure else muted)
            speedLabel.text = if (speed > 0) "${bytes(speed)}/s" else ""
            progress.isIndeterminate = value < 0 && action == "pause"
            progress.progress = value.coerceIn(0, 100)
            progress.progressTintList = ColorStateList.valueOf(if (data["status"] == "completed") success else accent)
            control.text = if (action == "pause") "暂停" else "继续"
            control.contentDescription = "${control.text} ${title.text}"
            control.isEnabled = !busy && action.isNotEmpty()
            control.visibility = if (action.isNotEmpty()) View.VISIBLE else View.GONE
        }
    }

    private fun send(action: String, id: String? = null) {
        if (busy) return
        if (action == "openDownloads") {
            try { app.startActivity(Intent(app, MainActivity::class.java).setAction(OPEN_DOWNLOADS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)) }
            catch (error: Exception) { report("download.overlay_open_failed", error) }
        }
        busy = true; bind()
        command(action, id) { success ->
            busy = false
            if (visible) bind()
            if (!success) Toast.makeText(app, "操作未完成，请打开下载管理查看", Toast.LENGTH_SHORT).show()
        }
    }

    private enum class DragOperation { MOVE, RESIZE, WIDTH, HEIGHT }

    private fun drag(view: View, operation: DragOperation = DragOperation.MOVE) {
        val slop = ViewConfiguration.get(context).scaledTouchSlop
        var downX = 0f; var downY = 0f
        var initial = OverlayBounds(0, 0, 1, 1)
        var moved = false
        view.setOnTouchListener { target, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; downY = event.rawY; moved = false
                    initial = if (collapsed) bubbleBounds else panelBounds
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - downX).toInt(); val dy = (event.rawY - downY).toInt()
                    if (abs(dx) > slop || abs(dy) > slop) moved = true
                    if (moved) move(when (operation) {
                        DragOperation.MOVE -> initial.copy(x = initial.x + dx, y = initial.y + dy)
                        DragOperation.RESIZE -> initial.copy(width = initial.width + dx, height = initial.height + dy)
                        DragOperation.WIDTH -> initial.copy(width = initial.width + dx)
                        DragOperation.HEIGHT -> initial.copy(height = initial.height + dy)
                    })
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (moved && collapsed) {
                        val (width, _) = screen()
                        move(bubbleBounds.copy(x = if (bubbleBounds.x + bubbleBounds.width / 2 < width / 2) 0 else width - bubbleBounds.width))
                    }
                    saveBounds()
                    if (!moved && event.actionMasked == MotionEvent.ACTION_UP) target.performClick()
                    true
                }
                else -> false
            }
        }
    }

    private fun move(bounds: OverlayBounds) {
        val layout = params ?: return
        val view = root ?: return
        val safe = fitted(bounds)
        if (collapsed) bubbleBounds = safe else {
            panelBounds = safe
            adaptPanel?.invoke(safe.width, safe.height)
        }
        layout.x = safe.x; layout.y = safe.y; layout.width = safe.width; layout.height = safe.height
        try { wm.updateViewLayout(view, layout) } catch (error: Exception) { fail(error) }
    }

    private fun saveBounds() {
        val density = context.resources.displayMetrics.density
        preferences.edit()
            .putInt("panelX", (panelBounds.x / density).toInt()).putInt("panelY", (panelBounds.y / density).toInt())
            .putInt("width", (panelBounds.width / density).toInt()).putInt("height", (panelBounds.height / density).toInt())
            .putInt("bubbleX", (bubbleBounds.x / density).toInt()).putInt("bubbleY", (bubbleBounds.y / density).toInt()).apply()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        if (visible) try { move(if (collapsed) bubbleBounds else panelBounds) } catch (error: Exception) { fail(error) }
    }
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onLowMemory() { }

    private fun bytes(value: Long): String {
        if (value < 1024) return "${value.coerceAtLeast(0)} B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var n = value / 1024.0; var index = 0
        while (n >= 1024 && index < units.lastIndex) { n /= 1024; index++ }
        return String.format(java.util.Locale.ROOT, "%.1f %s", n, units[index])
    }

    private inner class ProgressBall(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        init { isClickable = true; isFocusable = true; importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES }
        fun refresh() {
            contentDescription = "下载${snapshot["status"] ?: ""}，${number("progress").takeIf { it >= 0 }?.let { "$it%" } ?: "大小未知"}，点击展开下载管理"
            invalidate()
        }
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val cx = width / 2f; val cy = height / 2f
            val outerRadius = min(width, height) / 2f - dp(3)
            val radius = outerRadius - dp(5)
            paint.style = Paint.Style.FILL; paint.color = surface
            canvas.drawCircle(cx, cy, outerRadius, paint)
            paint.style = Paint.Style.STROKE; paint.strokeWidth = dp(1).toFloat()
            paint.color = if (dark) Color.rgb(64, 64, 67) else Color.rgb(224, 225, 232)
            canvas.drawCircle(cx, cy, outerRadius, paint)
            paint.strokeWidth = dp(3).toFloat()
            paint.color = if (dark) Color.rgb(64, 64, 67) else Color.rgb(233, 233, 240)
            canvas.drawCircle(cx, cy, radius, paint)
            val percent = (snapshot["progress"] as? Number)?.toInt() ?: -1
            val complete = number("count") > 0 && number("completed") == number("count")
            val tint = if (complete) success else if (number("active") == 0L && number("failed") > 0) failure else accent
            paint.color = tint; paint.strokeCap = Paint.Cap.ROUND
            val arc = RectF(cx - radius, cy - radius, cx + radius, cy + radius)
            canvas.drawArc(arc, -90f, if (percent < 0) 80f else percent.coerceIn(0, 100) * 3.6f, false, paint)
            paint.style = Paint.Style.FILL; paint.textAlign = Paint.Align.CENTER
            paint.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL); paint.textSize = dp(18).toFloat(); paint.color = tint
            canvas.drawText(if (percent >= 0) "$percent%" else "↓", cx, cy + dp(1), paint)
            paint.typeface = Typeface.DEFAULT; paint.textSize = 9f * context.resources.displayMetrics.density; paint.color = muted
            val label = if (number("active") > 0) bytes(number("speed")) + "/s" else snapshot["status"] as? String ?: "暂无任务"
            val available = radius * 1.65f
            if (paint.measureText(label) > available) paint.textSize *= available / paint.measureText(label)
            canvas.drawText(label, cx, cy + dp(15), paint)
        }
        override fun performClick(): Boolean { super.performClick(); return true }
    }
}
