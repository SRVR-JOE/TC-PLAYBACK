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
        caller.renderer = SpeechCueCallRenderer.shared
        caller.phrase = { kind, note, language in CueCallTemplates.text(kind, note: note, language: language) }
        caller.renderStep = { call, note, area, sampleRate in
            let voice = SpeechCueCallRenderer.shared
            if call.kind == .go {
                let audio = try await voice.renderGo(note: note, template: CueCallTemplates.template(for: area.language),
                                                     language: area.language, voiceID: area.voiceID,
                                                     rate: area.rate, sampleRate: sampleRate)
                return CueCallRenderedAudio(samples: audio.samples,
                                            goOnset: audio.goOnset.map { Int(($0 * sampleRate).rounded()) })
            }
            let samples = try await voice.render(call.text, language: area.language, voiceID: area.voiceID,
                                                 rate: area.rate, sampleRate: sampleRate)
            return CueCallRenderedAudio(samples: samples)
        }
        caller.noteLanguage = CueCallerUIModel.shared.noteLanguage
    }
}
