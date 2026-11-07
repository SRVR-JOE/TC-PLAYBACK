import Foundation

/// Plugs the language layer (on-device translation, call wording, speech) into the cue caller
/// engine. Called once at launch.
@MainActor
enum CueCallerWiring {
    private static var installed = false

    static func install(_ caller: CueCaller = .shared) {
        guard !installed else { return }
        installed = true
        caller.translator = AppleCueCallTranslator.shared
        // "eleven:" voices go to ElevenLabs (device voice as the fallback), the rest to the device.
        let router = CueCallVoiceRouter.shared
        router.onFallbacksChanged = { Task { @MainActor in CueCallVoicesModel.shared.refreshFallbacks() } }
        caller.renderer = router
        caller.phrase = { kind, note, language in CueCallTemplates.text(kind, note: note, language: language) }
        caller.renderStep = router.renderStep()
        caller.noteLanguage = CueCallerUIModel.shared.noteLanguage
    }
}
