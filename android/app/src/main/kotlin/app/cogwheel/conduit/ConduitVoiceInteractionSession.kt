package app.cogwheel.conduit

import android.Manifest
import android.app.assist.AssistContent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.text.Editable
import android.text.TextWatcher
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.ImageView
import android.widget.ScrollView
import android.widget.TextView

/**
 * The assistant sheet shown over the current app.
 *
 * A voice call, or dictation with a text reply, runs right here: the sheet
 * drives the app's shared Flutter engine ([ConduitEngineHost]) through
 * [AssistantOverlayBridge], and draws the state its Dart coordinator
 * (`lib/platform/android_assistant_overlay.dart`) sends back. Dismissing the
 * sheet returns to whatever was on screen; "open in app" continues the same
 * call or chat in MainActivity.
 */
class ConduitVoiceInteractionSession(context: Context) :
    VoiceInteractionSession(context), AssistantOverlayBridge.Listener {

    companion object {
        private const val TAG = "ConduitVoiceSession"
        private const val PREFS_FILE = "FlutterSharedPreferences"
        private const val TRIGGER_KEY = "flutter.android_assistant_trigger"
        private const val TRIGGER_OVERLAY = "overlay"
        private const val TRIGGER_NEW_CHAT = "new_chat"
        private const val TRIGGER_VOICE_CALL = "voice_call"
        private const val REPLY_MAX_HEIGHT_FRACTION = 0.35f
        private const val TOGGLE_ON_ICON_COLOR = 0xFF1F1F1F.toInt()

        /** The last localized labels from Dart, for the moment before it answers. */
        private var cachedLabels: Map<String, String> = emptyMap()
    }

    private var capturedContext: String? = null
    private var capturedScreenshot: Bitmap? = null

    private var bridge: AssistantOverlayBridge? = null
    private var engineAttached = false
    private var isDictating = false
    private var isBusy = false

    private var root: View? = null
    private lateinit var pageActions: View
    private lateinit var conversationCard: View
    private lateinit var titleText: TextView
    private lateinit var statusText: TextView
    private lateinit var transcriptText: TextView
    private lateinit var replyScroll: ScrollView
    private lateinit var replyText: TextView
    private lateinit var errorText: TextView
    private lateinit var callControls: View
    private lateinit var muteButton: View
    private lateinit var muteIcon: ImageView
    private lateinit var speakerButton: View
    private lateinit var speakerIcon: ImageView
    private lateinit var inputBar: View
    private lateinit var inputField: EditText
    private lateinit var sendButton: View
    private lateinit var dictationButton: View
    private lateinit var dictationIcon: ImageView
    private lateinit var voiceButton: View
    private lateinit var openAppButton: View
    private lateinit var endCallButton: View

    override fun onCreate() {
        super.onCreate()
        // The sheet has a text field; let the keyboard push it up.
        @Suppress("DEPRECATION")
        window?.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
    }

    override fun onCreateContentView(): View {
        if (getTriggerPreference() == TRIGGER_NEW_CHAT) {
            launchAppForNewChat()
            return View(context)
        }

        val view = layoutInflater.inflate(R.layout.assistant_overlay, null)
        bindViews(view)
        root = view
        return view
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        if (root == null) return

        val autoStartCall = getTriggerPreference() == TRIGGER_VOICE_CALL
        Log.d(TAG, "onShow autoStartCall=$autoStartCall mic=${hasMicrophonePermission()}")
        if (autoStartCall && !hasMicrophonePermission()) {
            // Only the app can ask for the permission; it starts the call there.
            launchAppForVoiceCall()
            return
        }

        attachEngine()
        if (autoStartCall) {
            render(
                mapOf(
                    "mode" to "call",
                    "status" to (cachedLabels["connecting"] ?: "…"),
                    "labels" to cachedLabels,
                )
            )
        } else {
            render(mapOf("mode" to "idle", "labels" to cachedLabels))
        }
        bridge?.send("overlayShown", mapOf("autoStartCall" to autoStartCall))
    }

    override fun onHide() {
        detachEngine()
        super.onHide()
    }

    override fun onDestroy() {
        detachEngine()
        super.onDestroy()
    }

    override fun onBackPressed() {
        finish()
    }

    private fun attachEngine() {
        if (engineAttached) return
        ConduitEngineHost.obtain(context)
        ConduitEngineHost.assistantAttached()
        engineAttached = true
        bridge = ConduitEngineHost.assistantOverlay?.also { it.listener = this }
        Log.d(TAG, "Engine attached, bridge=${bridge != null}")
    }

    private fun detachEngine() {
        if (!engineAttached) return
        engineAttached = false
        bridge?.let {
            // A sheet dismissed while the engine was still starting must not
            // start its call afterwards.
            it.clearPending()
            it.send("overlayDismissed")
            if (it.listener === this) it.listener = null
        }
        bridge = null
        ConduitEngineHost.assistantDetached()
        Log.d(TAG, "Engine detached")
    }

    private fun bindViews(view: View) {
        pageActions = view.findViewById(R.id.page_actions)
        conversationCard = view.findViewById(R.id.conversation_card)
        titleText = view.findViewById(R.id.title_text)
        statusText = view.findViewById(R.id.status_text)
        transcriptText = view.findViewById(R.id.transcript_text)
        replyScroll = view.findViewById(R.id.reply_scroll)
        replyText = view.findViewById(R.id.reply_text)
        errorText = view.findViewById(R.id.error_text)
        callControls = view.findViewById(R.id.call_controls)
        muteButton = view.findViewById(R.id.btn_mute)
        muteIcon = view.findViewById(R.id.icon_mute)
        speakerButton = view.findViewById(R.id.btn_speaker)
        speakerIcon = view.findViewById(R.id.icon_speaker)
        inputBar = view.findViewById(R.id.input_bar)
        inputField = view.findViewById(R.id.input_field)
        sendButton = view.findViewById(R.id.btn_send)
        dictationButton = view.findViewById(R.id.btn_dictation)
        dictationIcon = view.findViewById(R.id.icon_dictation)
        voiceButton = view.findViewById(R.id.btn_voice)
        openAppButton = view.findViewById(R.id.btn_open_app)
        endCallButton = view.findViewById(R.id.btn_end_call)

        // Tapping outside the sheet dismisses it.
        view.findViewById<View>(R.id.scrim).setOnClickListener { finish() }

        view.findViewById<View>(R.id.btn_summarize).setOnClickListener {
            launchAppWithContext()
        }
        view.findViewById<View>(R.id.btn_ask_about).setOnClickListener {
            launchAppWithScreenshot()
        }

        sendButton.setOnClickListener { sendInput() }
        inputField.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_SEND) {
                sendInput()
                true
            } else {
                false
            }
        }
        inputField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) = updateSendButton()
        })

        dictationButton.setOnClickListener {
            when {
                isDictating -> bridge?.send("stopDictation")
                !hasMicrophonePermission() -> launchApp()
                else -> bridge?.send("startDictation")
            }
        }
        voiceButton.setOnClickListener {
            if (hasMicrophonePermission()) {
                bridge?.send("startVoiceCall")
            } else {
                launchAppForVoiceCall()
            }
        }
        muteButton.setOnClickListener { bridge?.send("toggleMute") }
        speakerButton.setOnClickListener { bridge?.send("toggleSpeaker") }
        endCallButton.setOnClickListener {
            bridge?.send("endVoiceCall")
            finish()
        }
        openAppButton.setOnClickListener {
            // The call or chat keeps running; MainActivity attaches to the
            // same engine and shows it.
            bridge?.send("openInApp")
            launchApp()
        }
    }

    private fun sendInput() {
        val text = inputField.text?.toString()?.trim().orEmpty()
        if (text.isEmpty() || isBusy) return
        bridge?.send("sendText", mapOf("text" to text))
        inputField.setText("")
    }

    private fun updateSendButton() {
        val hasText = !inputField.text.isNullOrBlank()
        sendButton.visibility = if (hasText && !isDictating) View.VISIBLE else View.GONE
        sendButton.alpha = if (isBusy) 0.4f else 1f
    }

    override fun onStateChanged(state: Map<String, Any?>) {
        Log.d(TAG, "State mode=${state["mode"]} status=${state["status"]} error=${state["error"]}")
        if (root == null) return
        if (state["close"] == true) {
            finish()
            return
        }
        render(state)
    }

    private fun render(state: Map<String, Any?>) {
        @Suppress("UNCHECKED_CAST")
        val labels = (state["labels"] as? Map<String, String>).orEmpty()
        if (labels.isNotEmpty()) cachedLabels = labels
        applyLabels(cachedLabels)

        val mode = state["mode"] as? String ?: "idle"
        val inCall = mode == "call"
        val inConversation = mode != "idle"

        pageActions.visibility = if (inConversation) View.GONE else View.VISIBLE
        conversationCard.visibility = if (inConversation) View.VISIBLE else View.GONE
        callControls.visibility = if (inCall) View.VISIBLE else View.GONE
        inputBar.visibility = if (inCall) View.GONE else View.VISIBLE

        titleText.setTextOrHide(state["title"] as? String)
        statusText.setTextOrHide(state["status"] as? String)
        transcriptText.setTextOrHide(state["transcript"] as? String)
        errorText.setTextOrHide(state["error"] as? String)

        val reply = state["reply"] as? String
        if (reply.isNullOrEmpty()) {
            replyScroll.visibility = View.GONE
            replyText.text = ""
        } else {
            replyScroll.visibility = View.VISIBLE
            if (replyText.text.toString() != reply) {
                replyText.text = reply
                clampReplyHeight()
            }
        }

        val muted = state["isMuted"] == true
        setToggle(muteButton, muteIcon, muted)
        muteIcon.setImageResource(if (muted) R.drawable.ic_mic_off else R.drawable.ic_mic_on)
        muteButton.contentDescription = label(if (muted) "unmute" else "mute")
        val speakerOn = state["isSpeakerOn"] == true
        setToggle(speakerButton, speakerIcon, speakerOn)
        speakerButton.contentDescription = label(if (speakerOn) "speakerOff" else "speakerOn")

        isBusy = state["isBusy"] == true
        isDictating = state["isDictating"] == true
        setToggle(dictationButton, dictationIcon, isDictating)
        val dictationText = state["dictationText"] as? String
        if (isDictating && dictationText != null &&
            inputField.text?.toString() != dictationText
        ) {
            inputField.setText(dictationText)
            inputField.setSelection(dictationText.length)
        }
        updateSendButton()
    }

    private fun applyLabels(labels: Map<String, String>) {
        labels["hint"]?.let { inputField.hint = it }
        labels["send"]?.let { sendButton.contentDescription = it }
        labels["dictation"]?.let { dictationButton.contentDescription = it }
        labels["call"]?.let { voiceButton.contentDescription = it }
        labels["end"]?.let { endCallButton.contentDescription = it }
        labels["openInApp"]?.let { openAppButton.contentDescription = it }
        root?.let { view ->
            labels["summarize"]?.let {
                view.findViewById<TextView>(R.id.label_summarize).text = it
            }
            labels["askAbout"]?.let {
                view.findViewById<TextView>(R.id.label_ask_about).text = it
            }
        }
    }

    private fun label(key: String): String? = cachedLabels[key]

    private fun setToggle(button: View, icon: ImageView, on: Boolean) {
        button.setBackgroundResource(
            if (on) R.drawable.assistant_toggle_on_bg else R.drawable.voice_button_bg
        )
        if (on) icon.setColorFilter(TOGGLE_ON_ICON_COLOR) else icon.clearColorFilter()
        button.isActivated = on
    }

    /** Keeps a long reply scrollable inside the sheet, following its end. */
    private fun clampReplyHeight() {
        replyScroll.post {
            val maxHeight =
                (context.resources.displayMetrics.heightPixels * REPLY_MAX_HEIGHT_FRACTION).toInt()
            val params = replyScroll.layoutParams
            val wanted =
                if (replyText.height > maxHeight) maxHeight else ViewGroup.LayoutParams.WRAP_CONTENT
            if (params.height != wanted) {
                params.height = wanted
                replyScroll.layoutParams = params
            }
            replyScroll.fullScroll(View.FOCUS_DOWN)
        }
    }

    private fun TextView.setTextOrHide(value: String?) {
        if (value.isNullOrEmpty()) {
            visibility = View.GONE
        } else {
            text = value
            visibility = View.VISIBLE
        }
    }

    private fun hasMicrophonePermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    override fun onHandleAssist(
        data: Bundle?,
        structure: AssistStructure?,
        content: AssistContent?
    ) {
        super.onHandleAssist(data, structure, content)

        // Capture screen context
        val screenContext = StringBuilder()
        structure?.let {
            for (i in 0 until it.windowNodeCount) {
                traverseNode(it.getWindowNodeAt(i).rootViewNode, screenContext)
            }
        }
        capturedContext = screenContext.toString()

        // Capture screenshot from assist data
        data?.let {
            try {
                capturedScreenshot = it.getParcelable("screenshot")
                    ?: it.getParcelable("android.intent.extra.ASSIST_SCREENSHOT")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to get screenshot from bundle", e)
            }
        }
    }

    override fun onHandleScreenshot(screenshot: Bitmap?) {
        super.onHandleScreenshot(screenshot)
        capturedScreenshot = screenshot
    }

    private fun appIntent(): Intent =
        Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

    private fun startApp(intent: Intent) {
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch app", e)
        }
        finish()
    }

    private fun launchApp() = startApp(appIntent())

    private fun launchAppWithContext() {
        startApp(appIntent().apply {
            capturedContext?.let { putExtra("screen_context", it) }
        })
    }

    private fun launchAppWithScreenshot() {
        val intent = appIntent()
        capturedScreenshot?.let { bitmap ->
            try {
                val file = java.io.File(
                    context.cacheDir,
                    "assistant_screenshot_${System.currentTimeMillis()}.png"
                )
                java.io.FileOutputStream(file).use { outputStream ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)
                }
                intent.putExtra("screenshot_path", file.absolutePath)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to save screenshot", e)
            }
        }
        startApp(intent)
    }

    private fun launchAppForNewChat() {
        startApp(appIntent().apply { putExtra("start_new_chat", true) })
    }

    private fun launchAppForVoiceCall() {
        startApp(appIntent().apply { putExtra("start_voice_call", true) })
    }

    private fun getTriggerPreference(): String {
        return try {
            val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            prefs.getString(TRIGGER_KEY, TRIGGER_OVERLAY) ?: TRIGGER_OVERLAY
        } catch (e: Exception) {
            TRIGGER_OVERLAY
        }
    }

    private fun traverseNode(node: AssistStructure.ViewNode?, builder: StringBuilder) {
        if (node == null) return

        if (node.text != null) {
            builder.append(node.text).append("\n")
        }

        // Also check content description for accessibility text
        if (node.contentDescription != null) {
            builder.append(node.contentDescription).append("\n")
        }

        for (i in 0 until node.childCount) {
            traverseNode(node.getChildAt(i), builder)
        }
    }
}
