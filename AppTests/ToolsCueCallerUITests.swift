import XCTest
@testable import TCPlayback

@MainActor
final class ToolsCueCallerUITests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "cueCallerUI.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testOffByDefault() {
        let m = CueCallerUIModel(defaults: defaults)
        XCTAssertFalse(m.isEngaged)
        XCTAssertEqual(m.status, .off)
        XCTAssertEqual(m.settings.areas.count, 1)
    }

    func testSettingsRoundTripThroughModel() {
        let m = CueCallerUIModel(defaults: defaults)
        m.settings.source = .ltcInput
        m.settings.standbyLead = 8
        m.settings.sayStandby = false
        m.settings.includeMarkName = true
        m.settings.onlyMarksWithNotes = false
        m.settings.dedicatedCallChannels = false
        m.noteLanguage = "en-GB"

        let again = CueCallerUIModel(defaults: defaults)
        XCTAssertEqual(again.settings, m.settings)
        XCTAssertEqual(again.settings.source, .ltcInput)
        XCTAssertEqual(again.settings.standbyLead, 8)
        XCTAssertEqual(again.noteLanguage, "en-GB")
        XCTAssertEqual(CueCallerSettings.load(defaults), m.settings, "Stored in the contract's own format")
    }

    func testMasterToggleAndAreaTogglesPersist() {
        let m = CueCallerUIModel(defaults: defaults)
        m.isEngaged = true
        let a = m.addArea(name: "Cámaras", language: "es-MX")
        m.setAreaEnabled(a.id, false)

        let again = CueCallerUIModel(defaults: defaults)
        XCTAssertTrue(again.isEngaged)
        XCTAssertTrue(again.settings.enabled)
        XCTAssertEqual(again.area(a.id)?.enabled, false)
        XCTAssertNotEqual(again.status, .off)

        again.isEngaged = false
        XCTAssertFalse(CueCallerUIModel(defaults: defaults).isEngaged)
    }

    func testAddAndRemoveAreas() {
        let m = CueCallerUIModel(defaults: defaults)
        let first = m.settings.areas[0]
        let b = m.addArea(name: "Cameras")
        XCTAssertEqual(b.name, "Cameras 2", "Names stay unique")
        XCTAssertEqual(b.outputChannels, [2, 3], "New areas take the next free pair of outputs")
        XCTAssertEqual(b.language, m.noteLanguage)
        let c = m.addArea(name: "LX", language: "fr-FR")
        XCTAssertEqual(m.settings.areas.map(\.id), [first.id, b.id, c.id])
        XCTAssertEqual(m.areaLanguages, ["en-US", "fr-FR"])

        m.moveAreas(from: [2], to: 0)
        XCTAssertEqual(m.settings.areas.map(\.id), [c.id, first.id, b.id])

        m.removeArea(first.id)
        m.removeAreas(at: [0])
        XCTAssertEqual(m.settings.areas.map(\.id), [b.id])
        XCTAssertEqual(CueCallerUIModel(defaults: defaults).settings.areas.map(\.id), [b.id])
    }

    func testAreaEditsPersist() {
        let m = CueCallerUIModel(defaults: defaults)
        let id = m.settings.areas[0].id
        let lane = UUID()
        m.updateArea(id) {
            $0.language = "ja-JP"; $0.voiceID = "voice.x"; $0.outputChannels = [4, 6]
            $0.laneIDs = [lane]; $0.gainDB = -6; $0.rate = 0.45
        }
        let a = CueCallerUIModel(defaults: defaults).area(id)
        XCTAssertEqual(a?.language, "ja-JP")
        XCTAssertEqual(a?.voiceID, "voice.x")
        XCTAssertEqual(a?.outputChannels, [4, 6])
        XCTAssertEqual(a?.laneIDs, [lane])
        XCTAssertEqual(a?.gainDB, -6)
        XCTAssertEqual(a?.rate, 0.45)
    }

    func testOverridesSetClearAndPersist() {
        let m = CueCallerUIModel(defaults: defaults)
        let mark = UUID()
        XCTAssertNil(m.override(markID: mark, language: "es-MX"))
        m.setOverride("  Cámara 3, acércate  ", markID: mark, language: "es-MX")
        XCTAssertEqual(CueCallerUIModel(defaults: defaults).override(markID: mark, language: "es-MX"), "Cámara 3, acércate")
        XCTAssertNil(m.override(markID: mark, language: "fr-FR"), "Overrides are per language")
        m.setOverride("   ", markID: mark, language: "es-MX")
        XCTAssertNil(CueCallerUIModel(defaults: defaults).override(markID: mark, language: "es-MX"), "Blank clears")
    }

    func testTextHelpers() {
        XCTAssertEqual(CueCallerText.channels([]), "No outputs")
        XCTAssertEqual(CueCallerText.channels([2]), "Output 3")
        XCTAssertEqual(CueCallerText.channels([1, 0]), "Outputs 1–2")
        XCTAssertEqual(CueCallerText.channels([0, 3, 4]), "Outputs 1, 4, 5")
        let types = CuePointType.defaults
        XCTAssertEqual(CueCallerText.lanes([], types: types), "All lanes")
        XCTAssertEqual(CueCallerText.lanes([types[1].id], types: types), "Lights")
        XCTAssertEqual(CueCallerText.lanes(types.map(\.id), types: types), "Cue, Lights +2")
        XCTAssertTrue(CueCallerUIModel.sameLanguage("en-US", "en-GB"))
        XCTAssertFalse(CueCallerUIModel.sameLanguage("en-US", "es-MX"))
        XCTAssertEqual(CueCallerUIModel.commonLanguages.first?.id, "en-US")
        XCTAssertEqual(CueCallerStatus.following.label, "On · following")
    }

    func testSameLanguageNeedsNoTranslation() async {
        let m = CueCallerUIModel(defaults: defaults)
        let s = await m.translationStatus(for: "en-GB")
        XCTAssertEqual(s, .sameLanguage)
        let t = await m.translation(of: "Camera 3, go", to: "en-US")
        XCTAssertEqual(t, "Camera 3, go")
    }

    func testAssignedOutputsBeyondInterfaceStayVisible() {
        let m = CueCallerUIModel(defaults: defaults)
        let n = m.interfaceOutputCount
        XCTAssertEqual(m.outputChannels().count, n)
        let chs = m.outputChannels(including: [n + 3])
        XCTAssertEqual(chs.count, n + 4, "A channel the area already uses can still be seen and cleared")
        XCTAssertEqual(chs.last?.id, n + 3)
        let a = CueCallArea(name: "Far", language: "en-US", outputChannels: [0, n + 1])
        XCTAssertEqual(m.missingOutputs(a), [n + 1])
    }
}
