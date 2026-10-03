package com.asterlink.app
import android.app.Application
import com.asterlink.app.metrics.UsageMetrics
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/** Kept alive by the foreground service when the Activity is detached. */
class AsterLinkHost : Application(), DownloadServiceOwner, AppKeepAliveOwner {
    override val downloadKeepAlive: DownloadKeepAlive get() = bridge.downloadKeepAlive
    override lateinit var appKeepAlive: AppKeepAlive
        private set
    lateinit var engine: FlutterEngine
        private set
    lateinit var bridge: NativeBridge
        private set
    lateinit var playback: PlaybackBridge
        private set
    lateinit var diagnostics: DiagnosticRecorder
        private set
    internal lateinit var analytics: UsageMetrics
        private set
    override fun onCreate() {
        super.onCreate()
        diagnostics = DiagnosticRecorder(this)
        diagnostics.install()
        appKeepAlive = AppKeepAlive(this) { event, error -> diagnostics.record(event, error) }
        analytics = UsageMetrics(this, reportError = { name, error -> diagnostics.record(name, error) })
        analytics.start()
        engine = FlutterEngine(this)
        analytics.attach(engine.dartExecutor.binaryMessenger)
        bridge = NativeBridge(this, engine)
        playback = PlaybackBridge(this, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }
}
