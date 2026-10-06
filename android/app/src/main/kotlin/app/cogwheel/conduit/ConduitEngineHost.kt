package app.cogwheel.conduit

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The process's one Flutter engine.
 *
 * MainActivity and the assistant sheet ([ConduitVoiceInteractionSession])
 * share it, so a voice call or chat started over another app is the one the
 * app shows when opened, and no second isolate touches Hive or the auth
 * state. With no activity on screen the engine runs headless, so everything
 * registered here needs only a Context.
 *
 * The engine lives while either host uses it. When the last one goes it is
 * released after a short grace period, which lets Dart end a call cleanly and
 * keeps a quick re-invocation warm.
 */
object ConduitEngineHost {
    private const val TAG = "ConduitEngineHost"
    private const val ENGINE_ID = "conduit_main"
    private const val RELEASE_DELAY_MS = 3000L

    private val mainHandler = Handler(Looper.getMainLooper())
    private val releaseRunnable = Runnable { releaseIfUnused() }

    private var backgroundStreamingHandler: BackgroundStreamingHandler? = null
    private var nativeSttBridge: NativeSttBridge? = null
    private var nativeTtsBridge: NativeTtsBridge? = null
    private var imageGalleryBridge: ImageGalleryBridge? = null

    private var activityHosts = 0
    private var assistantHosts = 0

    /** The launch actions MainActivity forwards from its intents. */
    var assistantLaunch: AssistantLaunchChannel? = null
        private set

    /** The assistant sheet's channel. */
    var assistantOverlay: AssistantOverlayBridge? = null
        private set

    /** The shared engine, started (and its Dart entrypoint run) on first use. */
    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }

        val appContext = context.applicationContext
        val engine = FlutterEngine(appContext)
        // Host APIs go in before Dart runs, so its first calls find them.
        backgroundStreamingHandler = BackgroundStreamingHandler(appContext).also {
            it.setup(engine)
        }
        nativeSttBridge = NativeSttBridge(appContext).also { it.setup(engine) }
        nativeTtsBridge = NativeTtsBridge(appContext).also { it.setup(engine) }
        imageGalleryBridge = ImageGalleryBridge(appContext).also { it.setup(engine) }
        val messenger = engine.dartExecutor.binaryMessenger
        assistantLaunch = AssistantLaunchChannel(messenger)
        assistantOverlay = AssistantOverlayBridge(messenger)

        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        Log.d(TAG, "Engine started")
        return engine
    }

    fun activityAttached() {
        activityHosts += 1
        mainHandler.removeCallbacks(releaseRunnable)
    }

    fun activityDetached() {
        activityHosts = (activityHosts - 1).coerceAtLeast(0)
        scheduleReleaseIfUnused()
    }

    fun assistantAttached() {
        assistantHosts += 1
        mainHandler.removeCallbacks(releaseRunnable)
    }

    fun assistantDetached() {
        assistantHosts = (assistantHosts - 1).coerceAtLeast(0)
        scheduleReleaseIfUnused()
    }

    private fun scheduleReleaseIfUnused() {
        mainHandler.removeCallbacks(releaseRunnable)
        if (activityHosts == 0 && assistantHosts == 0) {
            mainHandler.postDelayed(releaseRunnable, RELEASE_DELAY_MS)
        }
    }

    private fun releaseIfUnused() {
        if (activityHosts > 0 || assistantHosts > 0) return
        val engine = FlutterEngineCache.getInstance().get(ENGINE_ID) ?: return
        FlutterEngineCache.getInstance().remove(ENGINE_ID)

        nativeSttBridge?.dispose()
        nativeTtsBridge?.dispose()
        imageGalleryBridge?.dispose()
        backgroundStreamingHandler?.cleanup()
        nativeSttBridge = null
        nativeTtsBridge = null
        imageGalleryBridge = null
        backgroundStreamingHandler = null
        assistantLaunch = null
        assistantOverlay = null

        engine.destroy()
        Log.d(TAG, "Engine released")
    }
}
