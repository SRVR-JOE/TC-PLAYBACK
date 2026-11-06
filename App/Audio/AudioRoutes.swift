import AVFoundation

/// Operator-facing names for audio routes.
enum AudioRoutes {
    static func name(for port: AVAudioSession.Port) -> String {
        switch port {
        case .usbAudio: return "USB Audio Interface"
        case .headphones: return "Headphones"
        case .builtInSpeaker: return "Speaker"
        case .builtInReceiver: return "Receiver"
        case .airPlay: return "AirPlay"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "Bluetooth"
        case .HDMI: return "HDMI"
        case .lineOut: return "Line Out"
        case .carAudio: return "CarPlay"
        case .displayPort: return "DisplayPort"
        case .thunderbolt: return "Thunderbolt Audio"
        case .builtInMic: return "Built-in Microphone"
        case .headsetMic: return "Headset Microphone"
        case .lineIn: return "Line In"
        default: return "Audio Output"
        }
    }

    static func name(for route: AVAudioSessionRouteDescription) -> String {
        guard let first = route.outputs.first else { return "No Output" }
        return name(for: first.portType)
    }

    static func inputName(for route: AVAudioSessionRouteDescription) -> String {
        guard let first = route.inputs.first else { return "the audio input" }
        return name(for: first.portType)
    }
}
