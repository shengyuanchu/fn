#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const server = createServer((request) => {
  request.resume();
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const timeout = (label, ms = 5000) => new Promise((_, reject) => {
  setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), ms);
});
try {
  let aborted = false;
  let fetchStartedResolve;
  const fetchStarted = new Promise((resolveStarted) => { fetchStartedResolve = resolveStarted; });
  const agent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    fetch(input, init) {
      init.signal.addEventListener("abort", () => { aborted = true; }, { once: true });
      fetchStartedResolve();
      return fetch(input, init);
    },
    env: {
      AI_GATEWAY_API_KEY: "native-core-cancel-key",
      FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${port}/stall`,
      MODEL: "native/test-model",
    },
  });
  const session = await agent.createSession();
  const turn = session.prompt("stall");
  await Promise.race([fetchStarted, timeout("stalled gateway fetch")]);
  turn.cancel();
  const result = await Promise.race([turn.result, timeout("native cancellation")]);
  assert.equal(result.stopReason, "cancelled");
  assert.equal(aborted, true, "turn cancellation must abort Node fetch");
  await session.close();
  assert.equal(await agent.close(), 0);
  console.log("native core cancellation passed: stalled request cancelled and runtime closed");
} finally {
  server.closeAllConnections();
  server.close();
}
