import Foundation

/// Compile-time and launch-time switches for unreleased features.
///
/// `crewCueing` gates everything under App/Crew/ (roles, shot script, rundown, countdowns,
/// follow state, master/follower sync, cue sheets). It is hard `false` in Release, so nothing
/// in the crew framework can reach a user. In DEBUG it turns on with the `-crewCueing` or
/// `-crewPreview` launch argument, or the `feature.crewCueing` user default.
enum FeatureFlags {
    static let crewCueingDefaultsKey = "feature.crewCueing"

    static var crewCueing: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-crewCueing") || args.contains("-crewPreview")
            || UserDefaults.standard.bool(forKey: crewCueingDefaultsKey)
        #else
        return false
        #endif
    }
}
