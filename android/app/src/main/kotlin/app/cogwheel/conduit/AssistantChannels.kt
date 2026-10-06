package app.cogwheel.conduit

import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The `app.cogwheel.conduit/assistant` channel: launch actions MainActivity
 * reads from its intents (a new chat, screen context, a screenshot).
 *
 * On a cold start the intent arrives before Dart has a handler, so the latest
 * action waits here until Dart says `assistantReady` and takes it (#514).
 */
class AssistantLaunchChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private var dartReady = false
    private var pending: Pair<String, Any?>? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "assistantReady" -> {
                    dartReady = true
                    val action = pending
                    pending = null
                    result.success(
                        action?.let { mapOf("method" to it.first, "argument" to it.second) }
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispatch(method: String, argument: Any? = null) {
        if (dartReady) {
            channel.invokeMethod(method, argument)
        } else {
            pending = method to argument
        }
    }

    companion object {
        private const val CHANNEL = "app.cogwheel.conduit/assistant"
    }
}

/**
 * The `app.cogwheel.conduit/assistant_overlay` channel between the assistant
 * sheet ([ConduitVoiceInteractionSession]) and its Dart coordinator
 * (`lib/platform/android_assistant_overlay.dart`).
 *
 * Calls to Dart made before it says `dartReady` are queued, so a sheet shown
 * while the engine is still starting runs its first action once Dart is up.
 */
class AssistantOverlayBridge(messenger: BinaryMessenger) {
    interface Listener {
        fun onStateChanged(state: Map<String, Any?>)
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private var dartReady = false
    private val pending = ArrayDeque<Pair<String, Any?>>()

    var listener: Listener? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "dartReady" -> {
                    dartReady = true
                    while (pending.isNotEmpty()) {
                        val (method, arguments) = pending.removeFirst()
                        channel.invokeMethod(method, arguments)
                    }
                    result.success(null)
                }
                "stateChanged" -> {
                    @Suppress("UNCHECKED_CAST")
                    val state = call.arguments as? Map<String, Any?>
                    if (state != null) listener?.onStateChanged(state)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun send(method: String, arguments: Any? = null) {
        if (dartReady) {
            channel.invokeMethod(method, arguments)
        } else {
            Log.d(TAG, "Queued $method until Dart is ready")
            pending.addLast(method to arguments)
        }
    }

    /** Drops queued calls a dismissed sheet no longer wants. */
    fun clearPending() {
        pending.clear()
    }

    companion object {
        private const val TAG = "AssistantOverlayBridge"
        private const val CHANNEL = "app.cogwheel.conduit/assistant_overlay"
    }
}
