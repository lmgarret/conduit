/// The Android assistant overlay coordinator.
///
/// When Conduit is the default digital assistant,
/// `ConduitVoiceInteractionSession.kt` draws a compact sheet over whatever is
/// on screen. Everything the sheet shows or does is decided here, over the
/// same voice-mode controller and chat pipeline the app uses: a voice call,
/// or dictation with a text reply. The sheet and MainActivity share one
/// Flutter engine (`ConduitEngineHost.kt`), so a call or chat started in the
/// sheet is the one the app shows when it is opened, and it is saved as a
/// normal chat.
///
/// Like the CarPlay coordinator, calls from the sheet arrive through an
/// [AssistantOverlayBridgePort] (`overlayShown`, `startVoiceCall`,
/// `endVoiceCall`, `toggleMute`, `toggleSpeaker`, `startDictation`,
/// `stopDictation`, `sendText`, `openInApp`, `overlayDismissed`), and the
/// sheet's state goes back as `stateChanged`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../core/utils/current_localizations.dart';
import '../features/chat/services/voice_input_service.dart';
import '../features/chat/voice_call/presentation/voice_call_launcher.dart';
import '../features/chat/voice_mode/chat_voice_mode_controller.dart';
import '../features/chat/voice_mode/voice_mode_error_text.dart';
import '../l10n/app_localizations.dart';
import '../shared/services/navigation_service.dart';

/// Answers one call from the sheet.
typedef AssistantOverlayCallHandler = Future<Object?> Function(
  String method,
  Object? arguments,
);

/// The native assistant sheet.
abstract interface class AssistantOverlayBridgePort {
  /// Installs the handler for calls from the sheet; null removes it.
  void setCallHandler(AssistantOverlayCallHandler? handler);

  /// Sends [method] to the sheet. Never throws: a runtime without the sheet
  /// simply drops it.
  Future<void> invoke(String method, [Object? arguments]);
}

/// The `app.cogwheel.conduit/assistant_overlay` channel that
/// `AssistantOverlayBridge.kt` talks to.
final class MethodChannelAssistantOverlayBridge
    implements AssistantOverlayBridgePort {
  const MethodChannelAssistantOverlayBridge({
    MethodChannel channel = const MethodChannel(
      'app.cogwheel.conduit/assistant_overlay',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  void setCallHandler(AssistantOverlayCallHandler? handler) {
    _channel.setMethodCallHandler(
      handler == null ? null : (call) => handler(call.method, call.arguments),
    );
  }

  @override
  Future<void> invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No native sheet in this runtime.
    }
  }
}

/// The host's assistant sheet. Null (the default) off Android.
final assistantOverlayBridgeProvider = Provider<AssistantOverlayBridgePort?>(
  (ref) => null,
);

/// Keeps the coordinator alive. The app reads it before its first frame: the
/// assistant can start the engine with no activity on screen.
final androidAssistantOverlayProvider = Provider<void>((ref) {
  final bridge = ref.watch(assistantOverlayBridgeProvider);
  if (bridge == null) return;
  AndroidAssistantOverlayCoordinator(ref, bridge).initialize();
});

enum AssistantOverlayMode { idle, call, chat }

final class AndroidAssistantOverlayCoordinator {
  AndroidAssistantOverlayCoordinator(
    this._ref,
    this._bridge, {
    AppLocalizations Function()? localizations,
  }) : _localizations = localizations ?? currentAppLocalizations;

  final Ref _ref;
  final AssistantOverlayBridgePort _bridge;
  final AppLocalizations Function() _localizations;

  bool _visible = false;
  bool _handingOff = false;
  bool _callStartedHere = false;
  bool _conversationStarted = false;
  AssistantOverlayMode _mode = AssistantOverlayMode.idle;
  String? _error;

  String _chatUserText = '';
  String _chatReply = '';
  bool _chatBusy = false;
  int? _messageCountBeforeSend;

  bool _dictating = false;
  String _dictationText = '';
  StreamSubscription<String>? _dictationSubscription;

  String? _lastSentStateKey;

  @visibleForTesting
  AssistantOverlayMode get mode => _mode;

  void initialize() {
    _bridge.setCallHandler(handleCall);
    _ref.listen<ChatVoiceModeSnapshot>(
      chatVoiceModeControllerProvider,
      (previous, next) => _handleVoiceSnapshot(previous, next),
    );
    _ref.listen<List<ChatMessage>>(
      chatMessagesProvider,
      (_, messages) => _handleChatChanged(messages),
    );
    _ref.listen<String?>(
      streamingContentProvider,
      (_, _) => _handleChatChanged(_ref.read(chatMessagesProvider)),
    );
    _ref.onDispose(() {
      _bridge.setCallHandler(null);
      unawaited(_dictationSubscription?.cancel());
    });
    unawaited(_bridge.invoke('dartReady'));
  }

  /// Answers one call from the sheet. Never throws: a failure shows as the
  /// sheet's error.
  Future<Object?> handleCall(String method, Object? arguments) async {
    try {
      switch (method) {
        case 'overlayShown':
          final args = arguments is Map ? arguments : const {};
          await _handleShown(autoStartCall: args['autoStartCall'] == true);
        case 'startVoiceCall':
          await _startVoiceCall();
        case 'endVoiceCall':
          await _endVoiceCall();
        case 'toggleMute':
          await _ref
              .read(chatVoiceModeControllerProvider.notifier)
              .toggleMute();
        case 'toggleSpeaker':
          await _ref
              .read(chatVoiceModeControllerProvider.notifier)
              .toggleSpeakerphone();
        case 'startDictation':
          await _startDictation();
        case 'stopDictation':
          await _stopDictation();
        case 'sendText':
          final args = arguments is Map ? arguments : const {};
          await _sendText(args['text'] as String? ?? '');
        case 'openInApp':
          _handingOff = true;
        case 'overlayDismissed':
          await _handleDismissed();
        default:
          DebugLogger.log(
            'Unknown assistant overlay method: $method',
            scope: 'assistant/overlay',
          );
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'overlay-method',
        scope: 'assistant/overlay',
        error: error,
        stackTrace: stackTrace,
      );
      _error = _localizations().errorMessage;
      _publish();
    }
    return null;
  }

  Future<void> _handleShown({required bool autoStartCall}) async {
    _visible = true;
    _handingOff = false;
    _callStartedHere = false;
    _conversationStarted = false;
    _error = null;
    _resetChat();
    _lastSentStateKey = null;
    if (_ref.read(chatVoiceModeControllerProvider).isActive) {
      _mode = AssistantOverlayMode.call;
      _publish();
    } else if (autoStartCall) {
      await _startVoiceCall();
    } else {
      _mode = AssistantOverlayMode.idle;
      _publish();
    }
  }

  Future<void> _handleDismissed() async {
    final handingOff = _handingOff;
    _visible = false;
    _handingOff = false;
    _mode = AssistantOverlayMode.idle;
    _resetChat();
    if (handingOff) return;

    if (_dictating) {
      await _stopDictation(sendResult: false);
    }
    final snapshot = _ref.read(chatVoiceModeControllerProvider);
    if (_callStartedHere &&
        (snapshot.isActive || snapshot.phase == ChatVoiceModePhase.error)) {
      await _ref.read(chatVoiceModeControllerProvider.notifier).stop();
    }
    _callStartedHere = false;
  }

  Future<void> _startVoiceCall() async {
    if (_ref.read(chatVoiceModeControllerProvider).isActive) {
      _mode = AssistantOverlayMode.call;
      _publish();
      return;
    }
    if (_dictating) {
      await _stopDictation(sendResult: false);
    }
    _mode = AssistantOverlayMode.call;
    _error = null;
    _publish();
    try {
      await _ref
          .read(voiceCallLauncherProvider)
          .launch(startNewConversation: !_conversationStarted);
      _callStartedHere = true;
      _conversationStarted = true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'overlay-voice-call-failed',
        scope: 'assistant/overlay',
        error: error,
        stackTrace: stackTrace,
      );
      final l10n = _localizations();
      _error =
          switch (error) {
            VoiceCallStartException(:final kind, :final message) =>
              voiceModeErrorText(l10n, kind: kind, message: message),
            StateError(:final message) => message,
            _ => null,
          } ??
          l10n.voiceCallFailed;
    }
    _publish();
  }

  Future<void> _endVoiceCall() async {
    final snapshot = _ref.read(chatVoiceModeControllerProvider);
    if (snapshot.isActive || snapshot.phase == ChatVoiceModePhase.error) {
      await _ref.read(chatVoiceModeControllerProvider.notifier).stop();
    }
    _callStartedHere = false;
  }

  void _handleVoiceSnapshot(
    ChatVoiceModeSnapshot? previous,
    ChatVoiceModeSnapshot next,
  ) {
    if (!_visible || _mode != AssistantOverlayMode.call) return;
    // A call this sheet started that ended cleanly elsewhere (the call
    // notification, the in-app overlay) closes the sheet.
    final endedCleanly =
        previous?.isActive == true &&
        !next.isActive &&
        next.phase != ChatVoiceModePhase.error;
    _publish(close: endedCleanly && _callStartedHere);
  }

  Future<void> _startDictation() async {
    if (_dictating) return;
    final l10n = _localizations();
    final service = _ref.read(voiceInputServiceProvider);
    try {
      if (!await service.initialize()) {
        throw StateError('Voice input unavailable');
      }
      final stream = await service.beginListening();
      _dictating = true;
      _dictationText = '';
      _error = null;
      _publish();
      await _dictationSubscription?.cancel();
      _dictationSubscription = stream.listen(
        (text) {
          _dictationText = text;
          _publish();
        },
        onDone: _handleDictationDone,
        onError: (Object _) => _handleDictationDone(),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'overlay-dictation-failed',
        scope: 'assistant/overlay',
        error: error,
        stackTrace: stackTrace,
      );
      _dictating = false;
      _error = l10n.voiceInputUnavailable;
      _publish();
    }
  }

  /// Stops listening. The recognizer's final text then arrives and is sent,
  /// unless [sendResult] is false.
  Future<void> _stopDictation({bool sendResult = true}) async {
    if (!_dictating) return;
    if (!sendResult) {
      _dictating = false;
      _dictationText = '';
      await _dictationSubscription?.cancel();
      _dictationSubscription = null;
    }
    await _ref.read(voiceInputServiceProvider).stopListening();
    _publish();
  }

  void _handleDictationDone() {
    if (!_dictating) return;
    _dictating = false;
    _dictationSubscription = null;
    final text = _dictationText.trim();
    _dictationText = '';
    _publish();
    // Dictation stops on its own when the speaker pauses; send what was
    // heard so the sheet stays hands-free.
    if (text.isNotEmpty && _visible) {
      unawaited(_sendText(text));
    }
  }

  Future<void> _sendText(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _chatBusy) return;
    if (_dictating) {
      await _stopDictation(sendResult: false);
    }

    _mode = AssistantOverlayMode.chat;
    _chatUserText = text;
    _chatReply = '';
    _chatBusy = true;
    _error = null;
    _messageCountBeforeSend = null;
    _publish();

    if (!await waitForChatEntryReady(_ref, requireModel: true)) {
      _chatBusy = false;
      _error = _localizations().errorMessage;
      _publish();
      return;
    }

    if (!_conversationStarted) {
      if (NavigationService.currentRoute != Routes.chat) {
        await NavigationService.navigateToChat();
      }
      startNewChat(_ref);
      _conversationStarted = true;
    }

    _messageCountBeforeSend = _ref.read(chatMessagesProvider).length;
    ChatSendPlaceholderHandle? pendingSend;
    try {
      await durableSend(
        _ref,
        text,
        null,
        onAssistantPlaceholderCreated: (handle) => pendingSend = handle,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'overlay-send-failed',
        scope: 'assistant/overlay',
        error: error,
        stackTrace: stackTrace,
      );
      recoverFailedChatSend(_ref, error, pendingSend);
      _chatBusy = false;
      _error = _localizations().errorMessage;
      _publish();
    }
  }

  void _handleChatChanged(List<ChatMessage> messages) {
    final countBefore = _messageCountBeforeSend;
    if (!_visible ||
        _mode != AssistantOverlayMode.chat ||
        countBefore == null) {
      return;
    }
    ChatMessage? reply;
    for (var i = messages.length - 1; i >= countBefore; i--) {
      if (messages[i].role == 'assistant') {
        reply = messages[i];
        break;
      }
    }
    if (reply == null) return;

    final streaming =
        reply.isStreaming && !assistantMessageResponseCompleted(reply);
    var content = reply.content;
    if (streaming && identical(reply, messages.last)) {
      final visible = _ref.read(streamingContentProvider);
      if (visible != null && visible.isNotEmpty) content = visible;
    }
    _chatReply = assistantOverlayPlainText(content);
    _chatBusy = streaming;
    final failure = reply.error;
    if (failure != null) {
      _chatBusy = false;
      _error = failure.content ?? _localizations().errorMessage;
    }
    _publish();
  }

  void _resetChat() {
    _chatUserText = '';
    _chatReply = '';
    _chatBusy = false;
    _messageCountBeforeSend = null;
    _dictationText = '';
  }

  void _publish({bool close = false}) {
    if (!_visible) return;
    final payload = statePayload(close: close);
    final key = payload.toString();
    if (key == _lastSentStateKey) return;
    _lastSentStateKey = key;
    unawaited(_bridge.invoke('stateChanged', payload));
  }

  /// What the sheet draws.
  @visibleForTesting
  Map<String, Object?> statePayload({bool close = false}) {
    final l10n = _localizations();
    final snapshot = _ref.read(chatVoiceModeControllerProvider);
    final inCall = _mode == AssistantOverlayMode.call;

    String? status;
    var transcript = '';
    var reply = '';
    var error = _error;
    if (inCall) {
      transcript = snapshot.transcript;
      reply = assistantOverlayPlainText(snapshot.assistantPreview);
      error ??= snapshot.phase == ChatVoiceModePhase.error
          ? voiceModeErrorText(
              l10n,
              kind: snapshot.errorKind,
              message: snapshot.errorMessage,
            )
          : null;
      status = switch (snapshot.phase) {
        ChatVoiceModePhase.idle ||
        ChatVoiceModePhase.starting => l10n.voiceCallConnecting,
        ChatVoiceModePhase.listening => l10n.voiceCallListening,
        ChatVoiceModePhase.sending => l10n.voiceCallProcessing,
        ChatVoiceModePhase.speaking => l10n.voiceCallSpeaking,
        ChatVoiceModePhase.paused => l10n.voiceCallPaused,
        ChatVoiceModePhase.muted => l10n.voiceCallMuted,
        ChatVoiceModePhase.ending ||
        ChatVoiceModePhase.ended ||
        ChatVoiceModePhase.error => l10n.voiceCallDisconnected,
      };
    } else if (_mode == AssistantOverlayMode.chat) {
      transcript = _chatUserText;
      reply = _chatReply;
      if (_chatBusy && reply.isEmpty) status = l10n.voiceCallProcessing;
    }
    if (_dictating) status = l10n.voiceStatusListening;

    return {
      'mode': _mode.name,
      'title': _ref.read(selectedModelProvider)?.name,
      'status': status,
      'transcript': transcript,
      'reply': reply,
      'error': error,
      'isMuted': snapshot.isMuted,
      'isSpeakerOn': snapshot.isSpeakerphoneEnabled,
      'isBusy': _chatBusy,
      'isDictating': _dictating,
      'dictationText': _dictating ? _dictationText : null,
      'close': close,
      'labels': {
        'hint': l10n.messageHintText,
        'send': l10n.send,
        'mute': l10n.mute,
        'unmute': l10n.unmute,
        'speakerOn': l10n.voiceCallSpeakerOn,
        'speakerOff': l10n.voiceCallSpeakerOff,
        'end': l10n.voiceCallEnd,
        'dictation': l10n.startDictation,
        'call': l10n.voiceCallTitle,
        'connecting': l10n.voiceCallConnecting,
        'openInApp': l10n.assistantOpenInApp,
        'summarize': l10n.assistantSummarizePage,
        'askAbout': l10n.assistantAskAboutPage,
      },
    };
  }
}

final _detailsBlock = RegExp(
  r'<details\b[\s\S]*?</details>',
  caseSensitive: false,
);
final _codeFence = RegExp(r'^\s*```.*$', multiLine: true);
final _heading = RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true);
final _quote = RegExp(r'^\s{0,3}>\s?', multiLine: true);
final _emphasis = RegExp(r'(\*\*|__)(.+?)\1');
final _link = RegExp(r'!?\[([^\]]*)\]\([^)]*\)');
final _extraBlankLines = RegExp(r'\n{3,}');

/// [markdown] as the plain text the sheet's small text view can show:
/// reasoning and tool blocks dropped, the common markdown marks removed.
@visibleForTesting
String assistantOverlayPlainText(String markdown) {
  var text = markdown.replaceAll(_detailsBlock, '');
  // A block still streaming has no closing tag yet.
  final openBlock = text.toLowerCase().indexOf('<details');
  if (openBlock >= 0) text = text.substring(0, openBlock);
  text = text
      .replaceAll(_codeFence, '')
      .replaceAll(_heading, '')
      .replaceAll(_quote, '')
      .replaceAllMapped(_emphasis, (match) => match[2]!)
      .replaceAllMapped(_link, (match) => match[1]!)
      .replaceAll('`', '')
      .replaceAll(_extraBlankLines, '\n\n');
  return text.trim();
}
