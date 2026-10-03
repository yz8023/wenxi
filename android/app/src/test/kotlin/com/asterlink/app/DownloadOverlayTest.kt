package com.asterlink.app

import android.app.Activity
import android.app.Application
import android.graphics.Rect
import android.provider.Settings
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE, application = Application::class)
class DownloadOverlayTest {
    private lateinit var overlay: DownloadOverlay
    private lateinit var activity: Activity
    private var allowed = true
    private val states = mutableListOf<Map<String, Any>>()
    private val actions = mutableListOf<Pair<String, String?>>()
    private val errors = mutableListOf<Throwable>()
    private fun value(done: Boolean = false) = mapOf(
        "count" to 1, "active" to if (done) 0 else 1, "completed" to if (done) 1 else 0,
        "speed" to 1024, "progress" to if (done) 100 else 40,
        "canPause" to !done, "canResume" to false, "status" to if (done) "全部完成" else "正在下载",
        "tasks" to listOf(mapOf("id" to "task-1", "name" to "测试文件.zip", "action" to if (done) "" else "pause", "progress" to 40))
    )
    @Before fun setup() {
        val app = RuntimeEnvironment.getApplication()
        app.getSharedPreferences("download_overlay", 0).edit().clear().commit()
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        overlay = DownloadOverlay(app, { activity }, { name, id, complete -> actions.add(name to id); complete(true) },
            { states.add(it) }, { _, error -> errors.add(error) }, { allowed })
    }
    @After fun cleanup() { overlay.close(); activity.finish() }
    private fun views(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { views(view.getChildAt(it)) } else emptyList()
    private fun button(label: String) = views(overlay.contentView!!).filterIsInstance<TextView>().first { it.text == label }
    private fun control(description: String) = views(overlay.contentView!!).first { it.contentDescription == description }

    @Test fun doesNotOpenUntilExplicitRequestAndCloseDoesNotPauseDownloads() {
        overlay.update(value())
        assertFalse(overlay.visible)
        overlay.show(value())
        assertTrue(overlay.visible)
        control("关闭悬浮窗，继续下载").performClick()
        assertFalse(overlay.visible)
        assertTrue(actions.isEmpty())
        assertTrue(errors.isEmpty())
    }
    @Test fun permissionIsRequestedAndDeniedPermissionDoesNotCreateWindow() {
        allowed = false
        assertEquals(true, overlay.show(value())["pendingPermission"])
        assertEquals(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, shadowOf(activity).nextStartedActivity.action)
        overlay.resumed()
        assertFalse(overlay.visible)
        assertFalse(overlay.pendingPermission)
    }
    @Test fun grantedPermissionReturnsToTheRequestedWindowAndRevocationClosesIt() {
        allowed = false
        overlay.show(value())
        allowed = true
        overlay.resumed()
        assertTrue(overlay.visible)
        allowed = false
        overlay.update(value())
        assertFalse(overlay.visible)
    }
    @Test fun canCollapseExpandAndRetainCompletedProgress() {
        overlay.show(value())
        control("收起为悬浮球").performClick()
        assertTrue(overlay.collapsed)
        overlay.update(value(done = true))
        assertTrue(overlay.visible)
        assertTrue(overlay.contentView!!.contentDescription.toString().contains("100%"))
        overlay.contentView!!.performClick()
        assertFalse(overlay.collapsed)
        assertTrue(views(overlay.contentView!!).filterIsInstance<TextView>().any { it.text.contains("全部完成") })
    }
    @Test fun taskAndTitleControlsReachTheExistingCoordinator() {
        overlay.show(value())
        button("暂停").performClick()
        control("打开下载管理").performClick()
        assertEquals(listOf("pause" to "task-1", "openDownloads" to null), actions)
    }
    @Test fun dragAndResizeAreClampedToTheScreen() {
        overlay.show(value())
        val initial = overlay.currentBounds
        val handle = views(overlay.contentView!!).first { it.contentDescription == "拖动调整小窗大小" }
        for ((action, x, y) in listOf(Triple(MotionEvent.ACTION_DOWN, 0f, 0f), Triple(MotionEvent.ACTION_MOVE, -1000f, -1000f), Triple(MotionEvent.ACTION_UP, -1000f, -1000f))) {
            MotionEvent.obtain(0, 10, action, x, y, 0).also { handle.dispatchTouchEvent(it); it.recycle() }
        }
        assertTrue(overlay.currentBounds.width > 0)
        assertTrue(overlay.currentBounds.height > 0)
        assertTrue(overlay.currentBounds.width <= initial.width)
        assertTrue(overlay.currentBounds.x >= 0)
        assertTrue(errors.isEmpty())
    }
    @Test fun boundsRemainVisibleOnSmallScreensAndAfterRotation() {
        val original = OverlayBounds(950, 700, 500, 650)
        assertEquals(OverlayBounds(0, 0, 240, 180), original.fit(240, 180, 280, 230))
        val rotated = original.fit(780, 360, 280, 230)
        assertTrue(rotated.x + rotated.width <= 780)
        assertTrue(rotated.y + rotated.height <= 360)
    }

    @Test @Config(qualifiers = "w360dp-h640dp-mdpi")
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun collapseRemainsVisibleAndSeparateFromResizeAtMinimumSize() {
        overlay.show(value())
        val handle = control("拖动调整小窗大小")
        for ((action, x, y) in listOf(Triple(MotionEvent.ACTION_DOWN, 0f, 0f), Triple(MotionEvent.ACTION_MOVE, -1000f, -1000f), Triple(MotionEvent.ACTION_UP, -1000f, -1000f))) {
            MotionEvent.obtain(0, 10, action, x, y, 0).also { handle.dispatchTouchEvent(it); it.recycle() }
        }
        assertEquals(200, overlay.currentBounds.width)
        assertEquals(180, overlay.currentBounds.height)
        assertBottomControlsFit()
        control("收起为悬浮球").performClick()
        assertTrue(overlay.collapsed)
    }

    @Test @Config(qualifiers = "w360dp-h640dp-mdpi")
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun largeTextAndThemeChangePreserveTheCollapseControl() {
        RuntimeEnvironment.setFontScale(1.5f)
        overlay.close()
        RuntimeEnvironment.getApplication().getSharedPreferences("download_overlay", 0).edit()
            .putInt("width", 200).putInt("height", 180).commit()
        val app = RuntimeEnvironment.getApplication()
        overlay = DownloadOverlay(app, { activity }, { _, _, done -> done(true) }, {}, { _, error -> errors.add(error) }, { allowed })
        overlay.show(value())
        assertBottomControlsFit()
        overlay.update(value() + ("dark" to true))
        assertBottomControlsFit()
        control("收起为悬浮球").performClick()
        overlay.update(value(done = true) + ("dark" to true))
        assertTrue(overlay.collapsed)
        assertTrue(overlay.visible)
        assertTrue(errors.isEmpty())
    }

    private fun assertBottomControlsFit() {
        val root = overlay.contentView!! as ViewGroup
        val bounds = overlay.currentBounds
        repeat(2) {
            root.measure(View.MeasureSpec.makeMeasureSpec(bounds.width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(bounds.height, View.MeasureSpec.EXACTLY))
            root.layout(0, 0, bounds.width, bounds.height)
        }
        val collapse = control("收起为悬浮球") as TextView
        val close = control("关闭悬浮窗，继续下载") as TextView
        val handle = control("拖动调整小窗大小")
        fun area(view: View): Rect = Rect(0, 0, view.width, view.height).also { root.offsetDescendantRectToMyCoords(view, it) }
        val buttonArea = area(collapse)
        val closeArea = area(close)
        val handleArea = area(handle)
        assertTrue(Rect(0, 0, root.width, root.height).contains(buttonArea))
        assertTrue(Rect(0, 0, root.width, root.height).contains(closeArea))
        assertTrue(Rect(0, 0, root.width, root.height).contains(handleArea))
        assertFalse(Rect.intersects(buttonArea, handleArea))
        assertFalse(Rect.intersects(buttonArea, closeArea))
        assertFalse(Rect.intersects(closeArea, handleArea))
        assertEquals(36, collapse.height)
        assertEquals(32, handle.width)
        assertEquals(32, handle.height)
        assertEquals("关闭", close.text.toString())
        assertEquals(0, close.layout.getEllipsisCount(0))
        assertEquals(0, collapse.layout.getEllipsisCount(0))
    }

    @Test @Config(qualifiers = "w360dp-h800dp-mdpi")
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun defaultWindowShowsFourCompleteTasksAndOldSmallWindowShowsTwo() {
        val data = value() + ("tasks" to (1..8).map { index ->
            mapOf("id" to "$index", "name" to "测试文件 $index.zip", "action" to "pause",
                "status" to "running", "label" to "正在下载", "progress" to 40,
                "downloaded" to 12345678, "total" to 987654321, "speed" to 1234567)
        })
        overlay.show(data)
        fun assertVisibleTasks(height: Int, minimum: Int) {
            val root = overlay.contentView!! as ViewGroup
            root.measure(View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            root.layout(0, 0, 320, height)
            val scroll = views(root).first { it.tag == "download-task-list" }
            val rows = views(scroll).filter { it.tag == "download-task-row" }
            assertTrue("Task list height: ${scroll.height}; row bounds: ${rows.map { it.top to it.bottom }}",
                rows.count { it.bottom <= scroll.height } >= minimum)
        }
        assertVisibleTasks(480, 4)
        assertVisibleTasks(360, 2)
        val root = overlay.contentView!! as ViewGroup
        val title = views(root).first { it.tag == "download-overlay-title" }
        val titleBounds = Rect(0, 0, title.width, title.height).also { root.offsetDescendantRectToMyCoords(title, it) }
        assertEquals(root.width / 2, titleBounds.centerX())
        assertFalse(views(root).any { it.contentDescription == "更多下载操作" })
        val close = control("关闭悬浮窗，继续下载")
        val closeBounds = Rect(0, 0, close.width, close.height).also { root.offsetDescendantRectToMyCoords(close, it) }
        assertTrue(closeBounds.top > root.height / 2)
    }

    @Test @Config(qualifiers = "w400dp-h800dp-mdpi")
    fun widthAndHeightCanBeAdjustedIndependentlyAndSaved() {
        overlay.show(value())
        fun dragBy(description: String, dx: Float, dy: Float) {
            val target = control(description)
            for ((action, x, y) in listOf(Triple(MotionEvent.ACTION_DOWN, 0f, 0f), Triple(MotionEvent.ACTION_MOVE, dx, dy), Triple(MotionEvent.ACTION_UP, dx, dy))) {
                MotionEvent.obtain(0, 10, action, x, y, 0).also { target.dispatchTouchEvent(it); it.recycle() }
            }
        }
        val initial = overlay.currentBounds
        dragBy("左右拖动调整小窗宽度", -90f, -200f)
        assertEquals(230, overlay.currentBounds.width)
        assertEquals(initial.height, overlay.currentBounds.height)
        dragBy("上下拖动调整小窗高度", 100f, -270f)
        assertEquals(230, overlay.currentBounds.width)
        assertEquals(210, overlay.currentBounds.height)
        dragBy("拖动调整小窗大小", -200f, -200f)
        assertEquals(200, overlay.currentBounds.width)
        assertEquals(180, overlay.currentBounds.height)
        dragBy("拖动调整小窗大小", 100f, 120f)
        assertEquals(300, overlay.currentBounds.width)
        assertEquals(300, overlay.currentBounds.height)
        val saved = overlay.currentBounds
        overlay.close()
        val app = RuntimeEnvironment.getApplication()
        overlay = DownloadOverlay(app, { activity }, { _, _, done -> done(true) }, {}, { _, error -> errors.add(error) }, { allowed })
        overlay.show(value())
        assertEquals(saved, overlay.currentBounds)
        assertTrue(errors.isEmpty())
    }

    @Test fun collapsedBallReplacesFailedStateWithTheLatestCompletedSnapshot() {
        overlay.show(value() + mapOf("active" to 0, "failed" to 1, "status" to "下载失败"))
        control("收起为悬浮球").performClick()
        assertTrue(overlay.contentView!!.contentDescription.contains("下载失败"))
        overlay.update(value())
        assertTrue(overlay.contentView!!.contentDescription.contains("正在下载"))
        overlay.update(value(done = true))
        assertTrue(overlay.contentView!!.contentDescription.contains("全部完成"))
        assertTrue(overlay.contentView!!.contentDescription.contains("100%"))
        assertFalse(overlay.contentView!!.contentDescription.contains("失败"))
    }
}
