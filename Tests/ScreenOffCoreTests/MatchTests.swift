import ScreenOffCore
import Testing

private let displays = [
    Display(id: 2, name: "LG ULTRAFINE", isBuiltin: false, isMain: true, isEnabled: true),
    Display(id: 1, name: "Built-in Retina Display", isBuiltin: true, isMain: false, isEnabled: true),
    Display(id: 3, name: "Studio Display", isBuiltin: false, isMain: false, isEnabled: false),
]

@Test func matchesByID() throws {
    #expect(try displays.match("3").name == "Studio Display")
}

@Test func matchesBySubstringCaseInsensitive() throws {
    #expect(try displays.match("lg").id == 2)
    #expect(try displays.match("studio").id == 3)
}

@Test func exactNameBeatsSubstring() throws {
    let list = displays + [Display(id: 4, name: "Studio Display 2", isBuiltin: false, isMain: false, isEnabled: true)]
    #expect(try list.match("studio display").id == 3)
}

@Test func ambiguousQueryThrows() {
    #expect(throws: ScreenOffError.ambiguous("display", ["Built-in Retina Display", "Studio Display"])) {
        try displays.match("display")
    }
}

@Test func unknownQueryThrows() {
    #expect(throws: ScreenOffError.noMatch("dell")) { try displays.match("dell") }
}
