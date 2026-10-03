import Foundation
import LocalLMLabSDKCore
import Testing

import LocalLMLabSDKMCPAppsHost

@Suite struct MCPToolInputFormTests {
    private func form(_ schema: String) -> MCPToolInputForm { MCPToolInputForm(schema: Data(schema.utf8)) }

    @Test func toolsWithoutInputsHaveAnEmptyForm() {
        #expect(form(#"{"type":"object","properties":{}}"#).isEmpty)
        #expect(form("{}").isEmpty)
        #expect(form("not json").isEmpty)
        #expect(form(#"{"type":"object"}"#).isEmpty)
    }

    @Test func mapsTheCommonTypes() {
        let f = form(#"""
        {"type":"object","required":["startDate"],"properties":{
          "startDate":{"type":"string","description":"When","pattern":"^x$"},
          "limit":{"type":"integer","default":10,"minimum":1},
          "ratio":{"type":"number"},
          "dryRun":{"type":"boolean","default":false},
          "mode":{"type":"string","enum":["a","b"]},
          "labels":{"type":"array","items":{"type":"string"}},
          "ids":{"type":"array","items":{"type":"integer"}},
          "filter":{"type":"object","properties":{}},
          "either":{"anyOf":[{"type":"string"},{"type":"integer"}]}
        }}
        """#)
        let byName = Dictionary(uniqueKeysWithValues: f.fields.map { ($0.name, $0) })
        #expect(byName["startDate"]?.kind == .string)
        #expect(byName["startDate"]?.isRequired == true)
        #expect(byName["startDate"]?.summary == "When")
        #expect(byName["limit"]?.kind == .integer)
        #expect(byName["limit"]?.defaultText == "10")
        #expect(byName["ratio"]?.kind == .number)
        #expect(byName["dryRun"]?.kind == .boolean)
        #expect(byName["dryRun"]?.defaultText == "false")
        #expect(byName["mode"]?.kind == .choice(["a", "b"]))
        #expect(byName["labels"]?.kind == .list(element: .string))
        #expect(byName["ids"]?.kind == .list(element: .integer))
        #expect(byName["filter"]?.kind == .json)
        #expect(byName["either"]?.kind == .json)
        #expect(f.hasRequiredFields)
    }

    @Test func requiredFieldsComeFirstThenAlphabetical() {
        let f = form(#"{"required":["z"],"properties":{"b":{"type":"string"},"a":{"type":"string"},"z":{"type":"string"}}}"#)
        #expect(f.fields.map(\.name) == ["z", "a", "b"])
    }

    @Test func nullableTypeListsResolveToTheRealType() {
        let f = form(#"{"properties":{"x":{"type":["string","null"]},"y":{"type":["string","integer"]}}}"#)
        #expect(f.fields.first { $0.name == "x" }?.kind == .string)
        #expect(f.fields.first { $0.name == "y" }?.kind == .json)  // ambiguous: raw JSON
    }

    @Test func nonStringEnumsFallBackToJSON() {
        #expect(form(#"{"properties":{"n":{"enum":[1,2,3]}}}"#).fields[0].kind == .json)
    }

    @Test func buildsTypedArgumentsAndOmitsBlankOptionals() throws {
        let f = form(#"""
        {"required":["startDate"],"properties":{"startDate":{"type":"string"},"limit":{"type":"integer"},"ratio":{"type":"number"},
         "dryRun":{"type":"boolean"},"mode":{"type":"string","enum":["a","b"]},"labels":{"type":"array","items":{"type":"string"}},
         "ids":{"type":"array","items":{"type":"integer"}},"filter":{"type":"object"},"note":{"type":"string"}}}
        """#)
        let args = try f.arguments(from: [
            "startDate": "today", "limit": " 20 ", "ratio": "0.5", "dryRun": "true", "mode": "b",
            "labels": "work, home ,", "ids": "1,2", "filter": #"{"a":[1]}"#, "note": "   ",
        ]).get()
        #expect(args["startDate"] == .string("today"))
        #expect(args["limit"] == .number(20))
        #expect(args["ratio"] == .number(0.5))
        #expect(args["dryRun"] == .bool(true))
        #expect(args["mode"] == .string("b"))
        #expect(args["labels"] == .array([.string("work"), .string("home")]))
        #expect(args["ids"] == .array([.number(1), .number(2)]))
        #expect(args["filter"] == .object(["a": .array([.number(1)])]))
        #expect(args["note"] == nil)  // blank optional is omitted
    }

    @Test func aBlankRequiredFieldIsAnError() {
        let f = form(#"{"required":["q"],"properties":{"q":{"type":"string"}}}"#)
        #expect(f.arguments(from: [:]) == .failure(.missingRequired("q")))
        #expect(f.arguments(from: ["q": "  "]) == .failure(.missingRequired("q")))
    }

    @Test func badInputIsReportedPerField() {
        let f = form(#"{"properties":{"n":{"type":"integer"},"x":{"type":"number"},"b":{"type":"boolean"},"m":{"enum":["a"]},"j":{"type":"object"},"ids":{"type":"array","items":{"type":"integer"}}}}"#)
        func err(_ k: String, _ v: String) -> MCPToolInputError? {
            if case .failure(let e) = f.arguments(from: [k: v]) { return e }
            return nil
        }
        #expect(err("n", "1.5") == .invalid(field: "n", reason: "must be a whole number"))
        #expect(err("x", "abc") != nil)
        #expect(err("x", "nan") != nil)
        #expect(err("b", "maybe") != nil)
        #expect(err("m", "z") != nil)
        #expect(err("j", "{oops") != nil)
        #expect(err("ids", "1,two") != nil)
    }

    @Test func aBooleanFieldNeverBlocksLaunchWhenBlank() throws {
        let f = form(#"{"required":["flag"],"properties":{"flag":{"type":"boolean"}}}"#)
        let args = try f.arguments(from: ["flag": ""]).get()
        #expect(args["flag"] == .bool(false))
    }

    @Test func realTodoistScheduleSchemaYieldsAUsableForm() {
        // Trimmed from Todoist's find-tasks-by-date inputSchema (fetched live 2026-09-20).
        let f = form(#"""
        {"type":"object","properties":{"cursor":{"type":"string"},"labels":{"type":"array","items":{"type":"string"}},
         "startDate":{"type":"string","pattern":"^(\\d{4}-\\d{2}-\\d{2}|today)$"},"daysCount":{"default":1,"minimum":1,"type":"integer","maximum":30},
         "limit":{"default":10,"type":"integer"},"overdueOption":{"type":"string","enum":["overdue-only","include-overdue","exclude-overdue"]}}}
        """#)
        #expect(!f.isEmpty)
        #expect(!f.hasRequiredFields)
        #expect(f.fields.first { $0.name == "overdueOption" }?.kind == .choice(["overdue-only", "include-overdue", "exclude-overdue"]))
        #expect(f.fields.first { $0.name == "daysCount" }?.defaultText == "1")
    }
}
