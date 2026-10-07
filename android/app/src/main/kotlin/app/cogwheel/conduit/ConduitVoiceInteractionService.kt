package app.cogwheel.conduit

import android.service.voice.VoiceInteractionService

/**
 * The service Android binds when Conduit is the default digital assistant.
 *
 * It only has to exist: `res/xml/voice_interaction_service.xml` names
 * [ConduitVoiceInteractionSessionService], which creates the sheet each time
 * the assistant is invoked. The system binds the two as different interfaces,
 * so they must be separate services.
 */
class ConduitVoiceInteractionService : VoiceInteractionService()
