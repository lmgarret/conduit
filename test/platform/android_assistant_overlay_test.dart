import 'package:conduit/features/chat/voice_call/presentation/voice_call_launcher.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/platform/android_assistant_overlay.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

/// The native sheet, as the coordinator sees it: what it sends is recorded,
/// and [call] plays a call from the sheet.
final class _FakeBridge implements AssistantOverlayBridgePort {
  final calls = <({String method, Object? arguments})>[];
  AssistantOverlayCallHandler? handler;

  @override
  void setCallHandler(AssistantOverlayCallHandler? handler) =>
      this.handler = handler;

  @override
  Future<void> invoke(String method, [Object? arguments]) async {
    calls.add((method: method, arguments: arguments));
  }

  Future<Object?> call(String method, [Object? arguments]) =>
      handler!(method, arguments);

  List<Map<String, Object?>> get states => [
    for (final call in calls)
      if (call.method == 'stateChanged')
        call.arguments! as Map<String, Object?>,
  ];
}

void main() {
  late _FakeBridge bridge;
  late _FakeVoiceCallController voice;
  late _FakeLauncher launcher;
  late ProviderContainer container;

  setUp(() {
    bridge = _FakeBridge();
    voice = _FakeVoiceCallController();
    final coordinatorProvider = Provider<void>((ref) {
      AndroidAssistantOverlayCoordinator(
        ref,
        bridge,
        localizations: () => lookupAppLocalizations(const Locale('en')),
      ).initialize();
    });
    container = ProviderContainer(
      overrides: [
        chatVoiceModeControllerProvider.overrideWith(() => voice),
        voiceCallLauncherProvider.overrideWith(_FakeLauncher.new),
        chatMessagesProvider.overrideWith(_FakeMessages.new),
        selectedModelProvider.overrideWithValue(
          const Model(id: 'test-model', name: 'Test Model'),
        ),
      ],
    );
    launcher = container.read(voiceCallLauncherProvider) as _FakeLauncher;
    container.read(coordinatorProvider);
  });

  tearDown(() => container.dispose());

  test('tells the sheet Dart is ready', () {
    expect(bridge.calls.first.method, 'dartReady');
  });

  test('a voice-call invocation starts a call in a new chat', () async {
    await bridge.call('overlayShown', {'autoStartCall': true});

    expect(launcher.startNewConversation, [true]);
    final state = bridge.states.last;
    expect(state['mode'], 'call');
    expect(state['status'], 'Listening');
    expect(state['title'], 'Test Model');
  });

  test('dismissing the sheet ends the call it started', () async {
    await bridge.call('overlayShown', {'autoStartCall': true});
    await bridge.call('overlayDismissed');

    expect(voice.stopCalls, 1);
  });

  test('opening the app keeps the call running', () async {
    await bridge.call('overlayShown', {'autoStartCall': true});
    await bridge.call('openInApp');
    await bridge.call('overlayDismissed');

    expect(voice.stopCalls, 0);
  });

  test('a call ended elsewhere closes the sheet', () async {
    await bridge.call('overlayShown', {'autoStartCall': true});
    voice.setSnapshot(
      const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.ended),
    );
    await Future<void>.delayed(Duration.zero);

    expect(bridge.states.last['close'], isTrue);
  });

  test('an idle invocation waits for the user', () async {
    await bridge.call('overlayShown', {'autoStartCall': false});

    expect(launcher.startNewConversation, isEmpty);
    expect(bridge.states.last['mode'], 'idle');
    expect((bridge.states.last['labels']! as Map)['openInApp'], 'Open in app');
  });

  test('a failed start shows the reason', () async {
    launcher.failure = StateError('Choose a model first.');
    await bridge.call('overlayShown', {'autoStartCall': true});

    expect(bridge.states.last['error'], 'Choose a model first.');
  });

  group('assistantOverlayPlainText', () {
    test('drops reasoning blocks, closed or still streaming', () {
      expect(
        assistantOverlayPlainText(
          '<details type="reasoning">\nthinking\n</details>\nHello',
        ),
        'Hello',
      );
      expect(
        assistantOverlayPlainText('Hi<details type="reasoning">\npartial'),
        'Hi',
      );
    });

    test('removes common markdown marks', () {
      expect(
        assistantOverlayPlainText(
          '## Title\n**bold** and `code` with [a link](https://x.y)\n'
          '> quoted\n```dart\nprint(1);\n```',
        ),
        'Title\nbold and code with a link\nquoted\n\nprint(1);',
      );
    });
  });
}

final class _FakeLauncher extends VoiceCallLauncher {
  _FakeLauncher(this._ref) : super(_ref);

  final Ref _ref;
  final startNewConversation = <bool>[];
  Object? failure;

  @override
  Future<void> launch({required bool startNewConversation}) async {
    final error = failure;
    if (error != null) throw error;
    this.startNewConversation.add(startNewConversation);
    await _ref
        .read(chatVoiceModeControllerProvider.notifier)
        .start(startNewConversation: startNewConversation);
  }
}

final class _FakeMessages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];
}

final class _FakeVoiceCallController extends ChatVoiceModeController {
  int stopCalls = 0;

  @override
  ChatVoiceModeSnapshot build() => const ChatVoiceModeSnapshot();

  @override
  Future<ChatVoiceModeStartResult> start({
    required bool startNewConversation,
    bool Function()? shouldStart,
    Model? admittedModel,
  }) async {
    state = const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening);
    return ChatVoiceModeStartResult.started;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    state = const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.ended);
  }

  void setSnapshot(ChatVoiceModeSnapshot snapshot) => state = snapshot;
}
