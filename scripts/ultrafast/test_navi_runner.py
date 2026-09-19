import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ["AI_GATEWAY_API_KEY"] = "vck_test"
os.environ["ANTHROPIC_API_KEY"] = "sk-test"
os.environ["NAVI_JEV_TRANSPORT"] = "vercel"
import navi_runner as nr
from jev_ultrafast import model as jev_model

class FakeResp:
    def __init__(self, status, body): self.status_code=status; self._b=body
    @property
    def is_error(self): return self.status_code >= 400
    def json(self): return self._b

captured = {}
def fake_post(url, json=None, headers=None):
    captured["url"]=url; captured["json"]=json; captured["headers"]=headers
    if "vercel" in url:
        return FakeResp(200, {"answers":{"operation":{"type":"choice","choice":"CLICK","probabilities":{"CLICK":0.9,"DONE":0.1}},
                                          "click_target":{"type":"choice","choice":"2","probabilities":{"1":0.2,"2":0.8}},
                                          "flag":{"type":"boolean","probability":0.97}},
                               "usage":{"inputTokens":300,"outputTokens":20},
                               "providerMetadata":{"typesafe":{"confidence":{"operation":0.66}}}})
    if "/v1/messages" in url:
        return FakeResp(200, {"content":[{"type":"text","text":"```json\n{\"text\": \"Zurich\"}\n```"}],"usage":{"input_tokens":50,"output_tokens":5}})
    raise AssertionError(url)
jev_model.CLIENT.post = fake_post

nr.install_adaptations()
body = {"model":"jev-latest","state":{"page":{}},"questions":{
    "operation":{"type":"choice","criteria":{"CLICK":"c","DONE":"d"},"instructions":"x"},
    "click_target":{"type":"choice","criteria":{"1":{},"2":{}},"instructions":"y"},
    "flag":{"type":"noul","instructions":"z"}}}
r = jev_model.post_json("https://api.typesafe.ai/v1/systemone", "unused", body)
assert captured["url"] == nr.VERCEL_URL, captured["url"]
assert captured["headers"]["ai-model-id"] == "typesafe-ai/jev"
assert captured["headers"]["Authorization"] == "Bearer vck_test"
assert captured["json"]["questions"]["flag"]["type"] == "boolean"
assert "model" not in captured["json"]
assert r["answers"]["operation"]["confidence"] == 0.66          # from providerMetadata
assert abs(r["answers"]["click_target"]["confidence"] - 0.6) < 1e-9  # derived 0.8-0.2
assert r["answers"]["flag"] == {"type":"noul","noul":0.97}
assert r["usage"]["input_tokens"] == 300
# validate_choice accepts the translated answers
jev_model.validate_choice(r["answers"]["operation"], {"CLICK","DONE"})
# text helper
import jev_ultrafast.agent as agent_module
assert agent_module.field_text is nr.field_text_claude
text, helper = jev_model.field_text({"goal":"g","field":{"label":"Where from?"},"page":{"title":"t","text":""},"recent_actions":[]})
assert text == "Zurich" and helper["model"] == "claude-haiku-4-5"
assert captured["headers"]["x-api-key"] == "sk-test"
print("runner adaptations OK")
