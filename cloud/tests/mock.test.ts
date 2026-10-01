import { describe, expect, it } from "vitest";
import { mockJevResponse } from "../lib/mock";

type Choice = { choice: string; probabilities: Record<string, number>; confidence: number };

function choice(criteria: Record<string, string>): Choice {
  const res = mockJevResponse({ questions: { q: { type: "choice", criteria } } });
  return (res.answers as Record<string, Choice>).q;
}

describe("mockJevResponse", () => {
  it("gives a lone option all the probability (the runner validates the sum)", () => {
    const a = choice({ "1": "only element" });
    expect(a.choice).toBe("1");
    expect(a.probabilities).toEqual({ "1": 1 });
    expect(a.confidence).toBe(1);
  });

  it("keeps several options summing to 1 with the first one chosen", () => {
    const a = choice({ CLICK: "c", WAIT: "w", DONE: "d", BLOCKED: "b" });
    expect(a.choice).toBe("CLICK");
    const sum = Object.values(a.probabilities).reduce((x, y) => x + y, 0);
    expect(Math.abs(sum - 1)).toBeLessThan(0.02);
    expect(a.probabilities.CLICK).toBe(0.82);
  });
});
