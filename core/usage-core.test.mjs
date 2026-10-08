import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname } from "node:path";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

// 실제 코어를 실행하되 파일·프로세스·시계만 대체한다.
// 사용자 인증 파일, Keychain, 네트워크, 실제 ccusage 에 접근하지 않는다.
const source = readFileSync(new URL("./usage-core.js", import.meta.url), "utf8")
  .replace(/^#!.*\n/, "")
  .replace(/^import\s[\s\S]*?from "node:[^"]+";\n/gm, "");

function fixture({ installed = true } = {}) {
  let time = new Date(2026, 9, 8, 10, 0).getTime();
  let failing = false;
  let cost = 12;
  let liveRequests = 0;
  const commands = [];
  const files = new Map();
  const cachePath = "/test/state/.claude-details.json";
  let output;
  class Clock extends Date {
    constructor(...args) { super(...(args.length ? args : [time])); }
    static now() { return time; }
  }
  const execSync = (command) => {
    commands.push(command);
    if (command.includes("blocks --active")) {
      if (failing) throw new Error("ccusage unavailable");
      return JSON.stringify({ blocks: [{
        isActive: true,
        startTime: new Clock(time - 3600_000).toISOString(),
        endTime: new Clock(time + 4 * 3600_000).toISOString(),
        costUSD: cost,
        totalTokens: 2000,
      }] });
    }
    if (command.includes("daily --breakdown")) {
      if (failing) throw new Error("ccusage unavailable");
      return JSON.stringify({ daily: [{ modelBreakdowns: [{
        modelName: "claude-fable-5", cost, inputTokens: 100,
      }] }] });
    }
    if (command.startsWith("security ")) {
      return JSON.stringify({ claudeAiOauth: { accessToken: "test-token" } });
    }
    if (command.includes("api.anthropic.com/api/oauth/usage")) {
      return JSON.stringify({ five_hour: { utilization: ++liveRequests } });
    }
    throw new Error(`Unexpected command: ${command}`);
  };
  return {
    commands,
    files,
    cachePath,
    advance(seconds) { time += seconds * 1000; },
    fail() { failing = true; },
    setCost(value) { cost = value; },
    detailCalls() { return commands.filter((s) => /blocks --active|daily --breakdown/.test(s)).length; },
    run(env = {}) {
      output = "";
      runInNewContext(source, {
        Date: Clock, dirname, homedir: () => "/test/home", execSync,
        readFileSync: (path) => {
          if (!files.has(path)) throw new Error("ENOENT");
          return files.get(path);
        },
        writeFileSync: (path, value) => files.set(path, value),
        existsSync: (path) => files.has(path) || path === "/test/bin/npx" ||
          (installed && path === "/test/bin/ccusage"),
        mkdirSync: () => {}, readdirSync: () => [],
        process: {
          execPath: "/test/bin/node",
          env: { AIU_STATE_DIR: "/test/state", EXCHANGE_RATE_KRW: "1400", ...env },
          stdout: { write: (value) => { output += value; } },
        },
      });
      return JSON.parse(output);
    },
  };
}

test("cached costs skip ccusage discovery while live usage still refreshes", () => {
  const f = fixture();
  const first = f.run();
  assert.equal(first.claudeModels.total, 12);
  assert.equal(f.detailCalls(), 2);
  const commandCount = f.commands.length;
  f.advance(120);
  const next = f.run();
  assert.equal(f.detailCalls(), 2);
  assert.equal(next.claudeModels.total, 12);
  assert.equal(next.claude.fiveHour.pct, first.claude.fiveHour.pct + 1);
  assert.equal(next.claudeBlock.remainMin, first.claudeBlock.remainMin - 2);
  assert.ok(next.claudeBlock.elapsedPct > first.claudeBlock.elapsedPct);
  assert.ok(f.commands.slice(commandCount).every((s) => !/ccusage|npx|command -v/.test(s)));
});

test("details refresh at ten minutes and manual refresh bypasses the cache", () => {
  const f = fixture();
  f.run();
  f.setCost(20);
  f.advance(599);
  assert.equal(f.run().claudeModels.total, 12);
  f.advance(1);
  assert.equal(f.run().claudeModels.total, 20);
  assert.equal(f.detailCalls(), 4);
  f.setCost(25);
  assert.equal(f.run({ AIU_FORCE_DETAILS: "1" }).claudeModels.total, 25);
  assert.equal(f.detailCalls(), 6);
});

test("failures preserve costs and throttle retries, including a failed cold start", () => {
  const f = fixture();
  f.run();
  f.advance(600);
  f.fail();
  assert.equal(f.run().claudeModels.total, 12);
  assert.equal(f.detailCalls(), 4);
  f.advance(120);
  assert.equal(f.run().claudeModels.total, 12);
  assert.equal(f.detailCalls(), 4);
  const cold = fixture();
  cold.fail();
  assert.equal(cold.run().claudeModels, null);
  cold.advance(120);
  assert.equal(cold.run().claudeModels, null);
  assert.equal(cold.detailCalls(), 2);
});

test("a date change discards yesterday's costs even when ccusage fails", () => {
  const f = fixture();
  f.run();
  f.advance(24 * 3600);
  f.fail();
  const next = f.run();
  assert.equal(next.claudeModels, null);
  assert.equal(next.claudeBlock, null);
  assert.equal(f.detailCalls(), 4);
});

test("expired cached blocks disappear instead of showing an active block", () => {
  const f = fixture();
  f.run();
  const cache = JSON.parse(f.files.get(f.cachePath));
  cache.block.endsAt = cache.checkedAt + 60;
  f.files.set(f.cachePath, JSON.stringify(cache));
  f.advance(120);
  assert.equal(f.run().claudeBlock, null);
  assert.equal(f.detailCalls(), 2);
});

test("AIU_NO_CCUSAGE overrides cached details and forced refresh", () => {
  const f = fixture();
  f.run();
  const next = f.run({ AIU_NO_CCUSAGE: "1", AIU_FORCE_DETAILS: "1" });
  assert.equal(next.claudeModels, null);
  assert.equal(next.claudeBlock, null);
  assert.equal(next.ccusage, false);
  assert.equal(f.detailCalls(), 2);
});

test("clock rollback and invalid cache cause a new aggregation", () => {
  const f = fixture();
  f.run();
  f.advance(-120);
  f.run();
  assert.equal(f.detailCalls(), 4);
  f.files.set(f.cachePath, "invalid JSON");
  f.run();
  assert.equal(f.detailCalls(), 6);
});

test("the npx fallback also runs only when details need refreshing", () => {
  const f = fixture({ installed: false });
  assert.equal(f.run().ccusage, true);
  assert.equal(f.detailCalls(), 2);
  assert.ok(f.commands.some((s) => s.includes('npx" -y ccusage blocks')));
  const commandCount = f.commands.length;
  f.advance(120);
  f.run();
  assert.equal(f.detailCalls(), 2);
  assert.ok(f.commands.slice(commandCount).every((s) => !/ccusage|npx|command -v/.test(s)));
});
