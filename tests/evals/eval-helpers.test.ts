import { describe, expect, test } from "bun:test";
import { buildEvalProcessEnv, shouldLoadDotEnv } from "./eval-helpers";

describe("eval helpers", () => {
  test("passes the selected eval model to fx through MODEL", () => {
    const previous = process.env.MODEL;
    process.env.MODEL = "ambient/model";

    try {
      const env = buildEvalProcessEnv("/tmp/fx-eval-home-test", "selected/model");

      expect(env.MODEL).toBe("selected/model");
      expect(env.HOME).toBe("/tmp/fx-eval-home-test");
      expect(env.NO_COLOR).toBe("1");
    } finally {
      if (previous === undefined) {
        delete process.env.MODEL;
      } else {
        process.env.MODEL = previous;
      }
    }
  });

  test("does not load repository dotenv files in a hermetic run", () => {
    expect(shouldLoadDotEnv({ FX_E2E_DISABLE_DOTENV: "1" })).toBe(false);
    expect(shouldLoadDotEnv({})).toBe(true);
  });
});
