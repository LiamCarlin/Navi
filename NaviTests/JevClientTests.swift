import Testing
import Foundation
@testable import Navi

struct JevClientTests {
    @Test func parsesDocumentedResponse() throws {
        let json = """
        {"model":"jev-latest","answers":{
          "department":{"type":"choice","choice":"billing","probabilities":{"billing":0.84,"technical":0.159,"sales":0.001},"confidence":0.596},
          "frustration":{"type":"score","score":1.035,"legend":{"0":"Calm","1":"Frustrated","2":"Angry"},"confidence":0.842},
          "is_urgent":{"type":"noul","noul":0.999}},
         "usage":{"input_tokens":312,"output_tokens":48}}
        """
        let r = try JevClient.parse(Data(json.utf8), latencyMs: 90)
        #expect(r["department"]?.choice == "billing")
        #expect(abs((r["department"]?.probabilities?["billing"] ?? 0) - 0.84) < 1e-9)
        #expect(abs((r["frustration"]?.score ?? 0) - 1.035) < 1e-9)
        #expect(r["is_urgent"]?.isTrue == true)
        #expect(r.inputTokens == 312)
    }

    @Test func encodesQuestions() throws {
        let q: [String: JevClient.Question] = [
            "intent": .choice(instructions: "Which", criteria: ["a": "A", "b": "B"]),
            "risk": .noul(instructions: "Is it risky?"),
            "level": .score(instructions: "How", criteria: ["low", "high"]),
        ]
        let data = try JSONEncoder().encode(q)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: [String: Any]]
        #expect(obj["intent"]?["type"] as? String == "choice")
        #expect((obj["intent"]?["criteria"] as? [String: String])?["a"] == "A")
        #expect(obj["risk"]?["type"] as? String == "noul")
        #expect((obj["level"]?["criteria"] as? [String]) == ["low", "high"])
    }
}
