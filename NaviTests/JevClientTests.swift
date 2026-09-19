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

struct JevVercelGatewayTests {
    /// Response shape from @ai-sdk/gateway's `gatewayEvaluationResponseSchema`.
    @Test func parsesGatewayResponse() throws {
        let json = """
        {"answers":{
           "route":{"type":"choice","choice":"billing","probabilities":{"billing":0.9,"shipping":0.08,"technical":0.02}},
           "quality":{"type":"score","score":2.97,"probabilities":{"0":0,"1":0,"2":0.02,"3":0.98}},
           "refunded":{"type":"boolean","probability":0.99}},
         "usage":{"inputTokens":283,"outputTokens":21},
         "providerMetadata":{"typesafe":{"confidence":{"route":0.71}}}}
        """
        let r = try JevClient.parseVercel(Data(json.utf8), latencyMs: 120)
        #expect(r.transport == .vercelGateway)
        #expect(r["route"]?.choice == "billing")
        #expect(abs((r["route"]?.confidence ?? 0) - 0.71) < 1e-9)          // from providerMetadata
        #expect(abs((r["quality"]?.score ?? 0) - 2.97) < 1e-9)
        #expect(abs((r["quality"]?.confidence ?? 0) - 0.96) < 1e-9)        // derived: 0.98 - 0.02
        #expect(r["refunded"]?.isTrue == true)
        #expect(abs((r["refunded"]?.noul ?? 0) - 0.99) < 1e-9)
        #expect(r.inputTokens == 283 && r.outputTokens == 21)
    }

    @Test func encodesBooleanSpellingForGateway() throws {
        let q: [String: JevClient.Question] = ["risky": .noul(instructions: "Is it risky?"),
                                               "intent": .choice(instructions: "Which", criteria: ["a": "A"])]
        let enc = JSONEncoder()
        enc.userInfo[JevClient.Question.booleanSpellingKey] = "boolean"
        let obj = try JSONSerialization.jsonObject(with: enc.encode(q)) as! [String: [String: Any]]
        #expect(obj["risky"]?["type"] as? String == "boolean")
        #expect(obj["intent"]?["type"] as? String == "choice")
        // Default spelling stays TypeSafe-native.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(q)) as! [String: [String: Any]]
        #expect(plain["risky"]?["type"] as? String == "noul")
    }

    @Test func buildsGatewayRequestHeaders() throws {
        setenv("AI_GATEWAY_API_KEY", "vck_test", 1)
        defer { unsetenv("AI_GATEWAY_API_KEY") }
        let (req, key) = try JevClient.buildRequest(transport: .vercelGateway, state: "s",
                                                    questions: ["ok": .noul(instructions: "x")], model: "jev-latest")
        #expect(req.url == JevClient.vercelEndpoint)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer vck_test")
        #expect(req.value(forHTTPHeaderField: "ai-model-id") == "typesafe-ai/jev")   // bare id mapped
        #expect(req.value(forHTTPHeaderField: "ai-evaluation-model-specification-version") == "4")
        #expect(req.value(forHTTPHeaderField: "ai-gateway-protocol-version") == "0.0.1")
        #expect(req.value(forHTTPHeaderField: "ai-gateway-auth-method") == "api-key")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] == nil)                                             // model travels in the header
        #expect(((body["questions"] as? [String: [String: Any]])?["ok"]?["type"] as? String) == "boolean")
        #expect(String(data: key.prefix(3), encoding: .utf8) == "vc:")
        let (req2, _) = try JevClient.buildRequest(transport: .vercelGateway, state: "s", questions: [:], model: "typesafe-ai/jev-fast")
        #expect(req2.value(forHTTPHeaderField: "ai-model-id") == "typesafe-ai/jev-fast")
    }

    @Test func resolvesTransportPreference() {
        unsetenv("TYPESAFE_API_KEY"); unsetenv("AI_GATEWAY_API_KEY")
        // No keys stored in this test environment's Keychain for the Navi service is assumed;
        // env vars drive resolution.
        setenv("AI_GATEWAY_API_KEY", "vck_test", 1)
        #expect(JevClient.resolveTransport(preference: .auto) == .vercelGateway)
        #expect(JevClient.resolveTransport(preference: .vercelGateway) == .vercelGateway)
        setenv("TYPESAFE_API_KEY", "ts_test", 1)
        #expect(JevClient.resolveTransport(preference: .auto) == .typesafe)
        #expect(JevClient.resolveTransport(preference: .vercelGateway) == .vercelGateway)
        unsetenv("TYPESAFE_API_KEY"); unsetenv("AI_GATEWAY_API_KEY")
    }

    @Test func derivedConfidence() {
        #expect(JevClient.derivedConfidence(["a": 1.0, "b": 0.0]) == 1.0)
        #expect(JevClient.derivedConfidence(["a": 0.5, "b": 0.5]) == 0.0)
        #expect(JevClient.derivedConfidence([:]) == 0.0)
    }
}
