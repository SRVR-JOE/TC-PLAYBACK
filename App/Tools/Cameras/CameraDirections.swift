import Foundation

// Camera direction vocabulary for the Cameras page: keywords (shot sizes, angles, moves, framing,
// calls) with a plain meaning, and ready-made direction lines to drop into a camera's mission.
// Lines use "{subject}" for the camera's subject ("Macklemore"); a camera with no subject reads
// "the artist".

struct CameraTerm: Identifiable, Hashable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case size, angle, movement, framing, calls
        var id: String { rawValue }
        var label: String {
            switch self {
            case .size: "Shot size"; case .angle: "Angle"; case .movement: "Movement"
            case .framing: "Framing"; case .calls: "Calls"
            }
        }
    }
    var term: String
    var abbr: String = ""
    var meaning: String
    var category: Category
    var id: String { term }
    /// "Medium close-up (MCU)".
    var display: String { abbr.isEmpty ? term : "\(term) (\(abbr))" }
}

struct CameraDirection: Identifiable, Hashable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case follow, framing, moments, band, crowd, discipline
        var id: String { rawValue }
        var label: String {
            switch self {
            case .follow: "Follow"; case .framing: "Framing"; case .moments: "Moments"
            case .band: "Band"; case .crowd: "Crowd"; case .discipline: "On air"
            }
        }
    }
    var template: String
    var category: Category
    var id: String { template }

    static let placeholder = "{subject}"

    /// The line for a camera: "{subject}" becomes its subject, or "the artist".
    func text(subject: String) -> String {
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var t = template.replacingOccurrences(of: Self.placeholder, with: s.isEmpty ? "the artist" : s)
        if t.hasPrefix("the artist") { t = "The artist" + t.dropFirst("the artist".count) }
        return t
    }
}

enum CameraDirections {
    static let terms: [CameraTerm] = [
        // Shot size, tightest first
        .init(term: "Extreme close-up", abbr: "ECU", meaning: "A detail only: eyes, mouth on the mic, hands on the keys.", category: .size),
        .init(term: "Close-up", abbr: "CU", meaning: "The face fills the frame, cut at the top of the shoulders.", category: .size),
        .init(term: "Medium close-up", abbr: "MCU", meaning: "Chest up. The go-to IMAG shot for a singer.", category: .size),
        .init(term: "Medium shot", abbr: "MS", meaning: "Waist up. Room for gestures and the mic hand.", category: .size),
        .init(term: "Cowboy", abbr: "MWS", meaning: "Mid-thigh up. Room for dancing and hands in the air.", category: .size),
        .init(term: "Wide shot", abbr: "WS", meaning: "Head to toe with a little room around them.", category: .size),
        .init(term: "Extreme wide", abbr: "EWS", meaning: "The whole stage or the whole house. The artist is small.", category: .size),
        .init(term: "Two-shot", abbr: "2S", meaning: "Two people in one frame, at any size.", category: .size),
        .init(term: "Group shot", meaning: "Three or more in frame: horns, singers, the whole band.", category: .size),
        .init(term: "Beauty shot", meaning: "A wide hero shot of the stage, lights and crowd.", category: .size),
        // Angle
        .init(term: "Eye level", meaning: "Lens at the subject's eyes. Neutral and honest.", category: .angle),
        .init(term: "Low angle", meaning: "Looking up at the subject. Makes them big and heroic.", category: .angle),
        .init(term: "High angle", meaning: "Looking down on the subject or the crowd.", category: .angle),
        .init(term: "Overhead", abbr: "Top shot", meaning: "Straight down from above: drum kit, dancers, the pit.", category: .angle),
        .init(term: "Profile", meaning: "Side on to the subject.", category: .angle),
        .init(term: "Over the shoulder", abbr: "OTS", meaning: "From behind the artist, past the shoulder, out to the crowd.", category: .angle),
        .init(term: "Dutch", meaning: "Tilted horizon. Use sparingly, for energy.", category: .angle),
        // Movement
        .init(term: "Push in", meaning: "Move or zoom closer, smoothly.", category: .movement),
        .init(term: "Pull out", meaning: "Move or zoom wider, smoothly.", category: .movement),
        .init(term: "Slow creep", meaning: "A push so slow you can barely see it. Good for ballads.", category: .movement),
        .init(term: "Pan", meaning: "Turn the camera left or right on the head.", category: .movement),
        .init(term: "Tilt", meaning: "Turn the camera up or down on the head.", category: .movement),
        .init(term: "Truck", meaning: "Move the whole camera sideways (handheld, track, Steadicam).", category: .movement),
        .init(term: "Track", meaning: "Move with the subject along the stage.", category: .movement),
        .init(term: "Boom up", abbr: "Jib up", meaning: "Raise the jib or camera height.", category: .movement),
        .init(term: "Boom down", abbr: "Jib down", meaning: "Lower the jib or camera height.", category: .movement),
        .init(term: "Follow", meaning: "Stay with the subject wherever they go.", category: .movement),
        .init(term: "Whip pan", meaning: "A very fast pan. Only when you're not on air, or on purpose.", category: .movement),
        .init(term: "Rack focus", meaning: "Move focus from one subject to another.", category: .movement),
        .init(term: "Lock off", meaning: "Don't move at all. Hold the frame.", category: .movement),
        // Framing
        .init(term: "Tight", meaning: "Closer than the current shot.", category: .framing),
        .init(term: "Loose", meaning: "A little wider than the current shot. Safer for movement.", category: .framing),
        .init(term: "Headroom", meaning: "Space between the top of the head and the frame.", category: .framing),
        .init(term: "Lead room", abbr: "Look room", meaning: "Space in front of where the subject faces or moves.", category: .framing),
        .init(term: "Center up", meaning: "Put the subject in the middle of the frame.", category: .framing),
        .init(term: "Rule of thirds", meaning: "Eyes on the top third line, subject off center.", category: .framing),
        .init(term: "Clean", meaning: "Nothing in the way: no stands, crew, cables or monitors.", category: .framing),
        .init(term: "Dirty", meaning: "A foreground shoulder, mic or crowd in frame on purpose.", category: .framing),
        .init(term: "Reframe", meaning: "Fix the composition, ideally while you're not on air.", category: .framing),
        .init(term: "Iso", meaning: "Isolate one person, on their own in the frame.", category: .framing),
        .init(term: "Pickup", meaning: "A short shot of a band member for the director to cut to.", category: .framing),
        .init(term: "Cutaway", meaning: "A shot away from the main action: crowd, hands, details.", category: .framing),
        // Calls
        .init(term: "Standby", abbr: "Ready", meaning: "The director is about to take your camera. Hold a good shot.", category: .calls),
        .init(term: "Take", abbr: "Go", meaning: "Your camera is going on air now.", category: .calls),
        .init(term: "On air", abbr: "Hot", meaning: "You're live (red tally). Smooth moves only.", category: .calls),
        .init(term: "Clear", meaning: "You're off air. Free to reframe or find the next shot.", category: .calls),
        .init(term: "Hold", meaning: "Stay on this shot. Don't move.", category: .calls),
        .init(term: "Find", meaning: "Look for a subject and be ready: \"find the drummer\".", category: .calls),
        .init(term: "IMAG", meaning: "Image magnification: the live shot on the big screens.", category: .calls),
        .init(term: "Safety", meaning: "The wide shot that's always usable, so the director has somewhere to go.", category: .calls),
    ]

    static let directions: [CameraDirection] = [
        // Follow
        .init(template: "{subject} all night.", category: .follow),
        .init(template: "Stay on {subject}. Never leave them.", category: .follow),
        .init(template: "Follow {subject} anywhere on stage.", category: .follow),
        .init(template: "When {subject} crosses to the other side, hand off to the next camera.", category: .follow),
        .init(template: "{subject} on the catwalk and B stage.", category: .follow),
        // Framing
        .init(template: "Mid to tight on {subject}.", category: .framing),
        .init(template: "Wide to mid on {subject}.", category: .framing),
        .init(template: "Chest up on {subject} for IMAG.", category: .framing),
        .init(template: "Keep the crowd in the bottom of the shot.", category: .framing),
        .init(template: "Shoot loose: the screens are big and {subject} moves a lot.", category: .framing),
        .init(template: "Keep it clean: no stands, crew or monitors in frame.", category: .framing),
        .init(template: "Low angle, looking up at {subject}.", category: .framing),
        .init(template: "Over the shoulder of {subject}, out to the crowd.", category: .framing),
        // Moments
        .init(template: "When {subject}'s hands go up, zoom out to get them in.", category: .moments),
        .init(template: "Go wide for pyro, confetti and big drops.", category: .moments),
        .init(template: "Slow push in on the ballad.", category: .moments),
        .init(template: "Tight on the face for the last chorus.", category: .moments),
        .init(template: "Hold still on the hits. Move between them.", category: .moments),
        .init(template: "Get the walk-on and the bow.", category: .moments),
        .init(template: "Find {subject} when they talk to the crowd.", category: .moments),
        // Band
        .init(template: "Drummer and horn pickups between lines.", category: .band),
        .init(template: "Horns, background singers and DJ.", category: .band),
        .init(template: "Look for solos and get there first.", category: .band),
        .init(template: "Solo: tight on the hands, then the face.", category: .band),
        .init(template: "Two-shot when {subject} works with a band member.", category: .band),
        // Crowd
        .init(template: "Crowd shots between songs.", category: .crowd),
        .init(template: "Find fans singing every word.", category: .crowd),
        .init(template: "Front row reactions, tight.", category: .crowd),
        .init(template: "Wide over the crowd from behind, stage in the top of frame.", category: .crowd),
        .init(template: "No crowd close-ups of kids or anyone who looks away from camera.", category: .crowd),
        // On air
        .init(template: "You're the safety: always hold a usable wide.", category: .discipline),
        .init(template: "Smooth moves only on tally. Reframe when you're clear.", category: .discipline),
        .init(template: "Never whip pan or rack off on air.", category: .discipline),
        .init(template: "Find your next shot as soon as you're clear.", category: .discipline),
        .init(template: "Avoid shooting the LED wall straight on (moiré).", category: .discipline),
    ]

    static func terms(in c: CameraTerm.Category) -> [CameraTerm] { terms.filter { $0.category == c } }
    static func directions(in c: CameraDirection.Category) -> [CameraDirection] { directions.filter { $0.category == c } }

    /// Adds a line to a mission: on its own line after existing text.
    static func append(_ line: String, to mission: String) -> String {
        let m = mission.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return mission }
        return m.isEmpty ? l : m + "\n" + l
    }

    /// Adds a keyword to a mission: after a space, mid-sentence (or as a new line after a full stop).
    static func appendKeyword(_ word: String, to mission: String) -> String {
        let m = mission.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return word }
        if m.hasSuffix("\n") { return m + word }
        return m + " " + word
    }
}
