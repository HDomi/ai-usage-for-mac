#!/usr/bin/env node
// AI Usage for Mac — 데이터 코어
// Claude Code · Cursor · Codex 사용량을 조회해 JSON 한 덩어리로 stdout 에 출력한다.
// 노치 앱(Swift)이 2분마다 이 스크립트를 실행해 결과를 그린다.
// 외부 패키지 없음. node 또는 bun 으로 실행.

import { execSync } from "node:child_process";
import {
  readFileSync,
  writeFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
} from "node:fs";
import { dirname } from "node:path";
import { homedir } from "node:os";

const CORE_VERSION = "1.0.0";
const HOME = homedir();
const now = Math.floor(Date.now() / 1000);

// 앱에서 실행되면 PATH 가 거의 비어 있음 → node 옆·nvm·Homebrew 를 앞에 붙인다
{
  const pathExtras = [
    dirname(process.execPath),
    `${HOME}/.bun/bin`,
    "/opt/homebrew/bin",
    "/usr/local/bin",
  ].filter((p) => {
    try {
      return existsSync(p);
    } catch {
      return false;
    }
  });
  process.env.PATH = [...pathExtras, process.env.PATH || "/usr/bin:/bin"].join(
    ":",
  );
}

const STATE_DIR =
  process.env.AIU_STATE_DIR ||
  `${HOME}/Library/Application Support/ai-usage-for-mac`;

function ensureStateDir() {
  try {
    mkdirSync(STATE_DIR, { recursive: true });
  } catch {}
}

function readJSON(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

function writeJSON(path, obj) {
  try {
    ensureStateDir();
    writeFileSync(path, JSON.stringify(obj));
  } catch {}
}

/**
 * nvm에 설치된 node 버전 bin 경로를 최신순으로 반환한다.
 * @param {string} name
 * @returns {string[]}
 */
function nvmBinCandidates(name) {
  const root = `${HOME}/.nvm/versions/node`;
  try {
    return readdirSync(root)
      .filter((v) => /^v\d/.test(v))
      .sort((a, b) => {
        const pa = a.slice(1).split(".").map(Number);
        const pb = b.slice(1).split(".").map(Number);
        for (let i = 0; i < 3; i++) {
          const d = (pb[i] || 0) - (pa[i] || 0);
          if (d) return d;
        }
        return 0;
      })
      .map((v) => `${root}/${v}/bin/${name}`);
  } catch {
    return [];
  }
}

/**
 * PATH에 의존하지 않고 실행 파일 절대경로를 찾는다.
 * @param {string} name
 * @param {string[]} [extra]
 * @returns {string}
 */
function findBin(name, extra = []) {
  const cands = [
    ...extra,
    `${dirname(process.execPath)}/${name}`,
    `${HOME}/.bun/bin/${name}`,
    `${HOME}/.nvm/versions/node/current/bin/${name}`,
    ...nvmBinCandidates(name),
    "/opt/homebrew/bin/" + name,
    "/usr/local/bin/" + name,
  ];
  for (const c of cands) {
    try {
      if (existsSync(c)) return c;
    } catch {}
  }
  try {
    const p = execSync(`command -v ${name} 2>/dev/null`, {
      encoding: "utf8",
    }).trim();
    if (p) return p;
  } catch {}
  return name;
}

/**
 * ccusage 실행 커맨드를 결정한다. 없으면 null (비용 상세만 생략).
 * @returns {string|null}
 */
function findCCUsage() {
  if (process.env.AIU_NO_CCUSAGE) return null;
  const bin = findBin("ccusage");
  try {
    if (bin && bin !== "ccusage" && existsSync(bin)) return bin;
    execSync(`${bin} --version 2>/dev/null`, { stdio: "ignore" });
    return bin;
  } catch {}
  return null;
}
const CCUSAGE = findCCUsage();

// ── 환율 ─────────────────────────────────────────────
const EXCHANGE_CACHE = `${STATE_DIR}/.exchange-rate.json`;
const DEFAULT_KRW_RATE = 1400;

function getExchangeRateKRW() {
  if (process.env.EXCHANGE_RATE_KRW) {
    return Number(process.env.EXCHANGE_RATE_KRW);
  }
  const cache = readJSON(EXCHANGE_CACHE);
  const age = cache?.fetchedAt ? now - cache.fetchedAt : Infinity;
  if (!cache?.rate || age > 6 * 3600) {
    try {
      const raw = execSync(
        `curl -fsL --max-time 3 "https://open.er-api.com/v6/latest/USD" 2>/dev/null`,
        { encoding: "utf8", timeout: 4000, stdio: ["ignore", "pipe", "ignore"] },
      );
      const data = JSON.parse(raw);
      if (data?.rates?.KRW) {
        const rate = Math.round(data.rates.KRW * 10) / 10;
        writeJSON(EXCHANGE_CACHE, { fetchedAt: now, rate });
        return rate;
      }
    } catch {}
  }
  return cache?.rate || DEFAULT_KRW_RATE;
}

// ── 1. Claude Code ────────────────────────
const MODEL_NAMES = {
  "claude-fable-5": "Fable 5",
  "claude-opus-5": "Opus 5",
  "claude-opus-4-8": "Opus 4.8",
  "claude-opus-4-7": "Opus 4.7",
  "claude-sonnet-5": "Sonnet 5",
  "claude-haiku-4-5-20251001": "Haiku 4.5",
};
const shortModel = (n) => MODEL_NAMES[n] || (n || "").replace("claude-", "");

/** ccusage 활성 블록 (비용·토큰). ccusage 없으면 null */
function getClaudeBlock() {
  if (!CCUSAGE) return null;
  try {
    const raw = execSync(`${CCUSAGE} blocks --active --json`, {
      encoding: "utf8",
      timeout: 20000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const data = JSON.parse(raw);
    const b =
      (data.blocks || []).find((x) => x.isActive) || (data.blocks || [])[0];
    if (!b) return null;
    const startTs = Math.floor(new Date(b.startTime).getTime() / 1000);
    const endTs = Math.floor(new Date(b.endTime).getTime() / 1000);
    const span = Math.max(1, endTs - startTs);
    const elapsedPct = Math.max(
      0,
      Math.min(100, ((now - startTs) / span) * 100),
    );
    return {
      elapsedPct,
      remainMin:
        b.projection?.remainingMinutes ??
        Math.max(0, Math.floor((endTs - now) / 60)),
      cost: b.costUSD || 0,
      tokens: b.totalTokens || 0,
      projCost: b.projection?.totalCost ?? null,
      costPerHour: b.burnRate?.costPerHour ?? null,
    };
  } catch {
    return null;
  }
}

/** ccusage 오늘 모델별 비용. ccusage 없으면 null */
function getClaudeModels() {
  if (!CCUSAGE) return null;
  try {
    const d = new Date();
    const ymd = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
    const raw = execSync(`${CCUSAGE} daily --breakdown --json --since ${ymd}`, {
      encoding: "utf8",
      timeout: 20000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const day = (JSON.parse(raw).daily || []).slice(-1)[0];
    if (!day) return null;
    const models = (day.modelBreakdowns || [])
      .map((m) => ({
        name: m.modelName,
        short: shortModel(m.modelName),
        cost: m.cost || 0,
        tokens:
          (m.inputTokens || 0) +
          (m.outputTokens || 0) +
          (m.cacheCreationTokens || 0) +
          (m.cacheReadTokens || 0),
      }))
      .filter((m) => m.cost > 0.005)
      .sort((a, b) => b.cost - a.cost);
    if (!models.length) return null;
    return { models, total: models.reduce((s, m) => s + m.cost, 0) };
  } catch {
    return null;
  }
}

const CLAUDE_USAGE_CACHE = `${STATE_DIR}/.claude-usage.json`;

function readClaudeToken() {
  if (existsSync(`${STATE_DIR}/.no-live`)) return null;
  try {
    const raw = execSync(
      'security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null',
      { encoding: "utf8", timeout: 3000, stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    const t = JSON.parse(raw)?.claudeAiOauth?.accessToken;
    if (t) return t;
  } catch {}
  try {
    const raw = readFileSync(`${HOME}/.claude/.credentials.json`, "utf8");
    return JSON.parse(raw)?.claudeAiOauth?.accessToken ?? null;
  } catch {}
  return null;
}

function fetchClaudeUsageLive() {
  const token = readClaudeToken();
  if (!token) return null;
  try {
    // 토큰이 ps 에 노출되지 않도록 stdin(-H @-) 으로 헤더 주입
    const raw = execSync(
      `/usr/bin/curl -fsS --max-time 5 -H @- -H "anthropic-beta: oauth-2025-04-20" https://api.anthropic.com/api/oauth/usage`,
      {
        encoding: "utf8",
        timeout: 8000,
        input: `Authorization: Bearer ${token}\n`,
        stdio: ["pipe", "pipe", "ignore"],
      },
    );
    const d = JSON.parse(raw);
    if (!d?.five_hour) return null;
    writeJSON(CLAUDE_USAGE_CACHE, { fetchedAt: now, data: d });
    return { data: d, measuredAt: now, live: true };
  } catch {
    return null;
  }
}

function readClaudeUsageFallback() {
  const c = readJSON(CLAUDE_USAGE_CACHE);
  if (c?.data?.five_hour)
    return { data: c.data, measuredAt: c.fetchedAt ?? 0, live: false };
  return null;
}

function getClaudeUsage() {
  const src = fetchClaudeUsageLive() ?? readClaudeUsageFallback();
  if (!src) return null;
  const { data: d, measuredAt, live } = src;
  try {
    const toTs = (iso) => (iso ? Math.floor(Date.parse(iso) / 1000) : null);
    const win = (o) =>
      o ? { pct: o.utilization ?? 0, resetsAt: toTs(o.resets_at) } : null;
    let fable = null;
    for (const l of d.limits || []) {
      const mdl = l.scope?.model?.display_name;
      if (l.group === "weekly" && mdl) {
        fable = { pct: l.percent ?? 0, resetsAt: toTs(l.resets_at), model: mdl };
        break;
      }
    }
    return {
      measuredAt,
      live,
      fiveHour: win(d.five_hour),
      weekly: win(d.seven_day),
      fable,
    };
  } catch {
    return null;
  }
}

// ── 2. Cursor AI ─────────────────────────────
const CURSOR_USAGE_CACHE = `${STATE_DIR}/.cursor-usage.json`;

function clampPct(v) {
  const n = Number(v);
  if (!Number.isFinite(n)) return null;
  return Math.min(100, Math.max(0, n));
}

/**
 * Cursor 대시보드의 Cursor Models / Other Models 사용률을 추출한다.
 * autoPercentUsed=Cursor Models, apiPercentUsed=Other Models.
 */
function resolveCursorPoolPct(d) {
  const pu = d?.planUsage || {};
  const autoUsed =
    clampPct(pu.autoPercentUsed) ??
    clampPct(
      String(d?.autoModelSelectedDisplayMessage || "").match(
        /(\d+(?:\.\d+)?)\s*%/,
      )?.[1],
    ) ??
    0;
  const apiUsed =
    clampPct(pu.apiPercentUsed) ??
    clampPct(
      String(d?.namedModelSelectedDisplayMessage || "").match(
        /(\d+(?:\.\d+)?)\s*%/,
      )?.[1],
    ) ??
    0;
  const usedPct =
    clampPct(pu.autoPercentUsed) != null
      ? autoUsed
      : (clampPct(pu.totalPercentUsed) ?? autoUsed);
  return { autoUsed, apiUsed, usedPct };
}

/**
 * Cursor 구독 상태. free 계정은 usage 가 0% 로 와서 100% 남음처럼 보이므로 걸러낸다.
 * @returns {boolean|null} true=구독 중, false=free, null=판단 불가
 */
function fetchCursorSubscribed(token) {
  try {
    const raw = execSync(
      `/usr/bin/curl -fsS --max-time 5 -H @- https://api2.cursor.sh/auth/full_stripe_profile`,
      {
        encoding: "utf8",
        timeout: 8000,
        input: `Authorization: Bearer ${token}\n`,
        stdio: ["pipe", "pipe", "ignore"],
      },
    ).trim();
    const p = JSON.parse(raw);
    if (!p || typeof p !== "object") return null;
    if (p.isTeamMember && p.teamMembershipType) return true;
    const type = String(
      p.individualMembershipType || p.membershipType || "",
    ).toLowerCase();
    if (!type) return null;
    return type !== "free";
  } catch {
    return null;
  }
}

function fetchCursorUsageLive() {
  try {
    const dbPath = `${HOME}/Library/Application Support/Cursor/User/globalStorage/state.vscdb`;
    if (!existsSync(dbPath)) return null;
    const token = execSync(
      `/usr/bin/sqlite3 "${dbPath}" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';"`,
      { encoding: "utf8", timeout: 3000, stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    if (!token) return null;

    if (fetchCursorSubscribed(token) === false) {
      writeJSON(CURSOR_USAGE_CACHE, { subscribed: false, measuredAt: now });
      return null;
    }

    const raw = execSync(
      `/usr/bin/curl -sL -X POST -H @- -H "Content-Type: application/json" -H "Connect-Protocol-Version: 1" -d "{}" https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`,
      {
        encoding: "utf8",
        timeout: 8000,
        input: `Authorization: Bearer ${token}\n`,
        stdio: ["pipe", "pipe", "ignore"],
      },
    ).trim();
    const d = JSON.parse(raw);
    if (!d?.planUsage) return null;

    const pu = d.planUsage;
    const { autoUsed, apiUsed, usedPct } = resolveCursorPoolPct(d);
    const res = {
      usedPct,
      remainPct: Math.max(0, 100 - usedPct),
      autoPercentUsed: autoUsed,
      apiPercentUsed: apiUsed,
      cycleEnd: d.billingCycleEnd
        ? Math.floor(Number(d.billingCycleEnd) / 1000)
        : null,
      displayMsg:
        d.autoModelSelectedDisplayMessage ||
        d.displayMessage ||
        d.namedModelSelectedDisplayMessage ||
        null,
      totalSpendCents: pu.totalSpend ?? null,
      includedSpendCents: pu.includedSpend ?? null,
      limitCents: pu.limit ?? null,
      measuredAt: now,
      live: true,
    };
    writeJSON(CURSOR_USAGE_CACHE, res);
    return res;
  } catch {
    return null;
  }
}

function readCursorUsageFallback() {
  const c = readJSON(CURSOR_USAGE_CACHE);
  if (!c || c.subscribed === false) return null;
  if (c.remainPct != null) return { ...c, live: false };
  return null;
}

function getCursorUsage() {
  return fetchCursorUsageLive() ?? readCursorUsageFallback();
}

// ── 3. Codex (ChatGPT) ─────────────────────────────
const CODEX_USAGE_CACHE = `${STATE_DIR}/.codex-usage.json`;
const CODEX_AUTH = `${HOME}/.codex/auth.json`;
const CODEX_OAUTH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";

function readCodexAuth() {
  const d = readJSON(CODEX_AUTH);
  const accessToken = d?.tokens?.access_token || d?.access_token || null;
  if (!accessToken) return null;
  return {
    accessToken,
    accountId: d?.tokens?.account_id || d?.account_id || null,
  };
}

/**
 * 만료된 Codex access_token 을 refresh_token 으로 갱신하고 auth.json 에 되쓴다.
 * refresh_token 은 회전되므로 반드시 저장한다.
 */
function refreshCodexAuth() {
  try {
    const d = JSON.parse(readFileSync(CODEX_AUTH, "utf8"));
    const refreshToken = d?.tokens?.refresh_token;
    if (!refreshToken) return null;
    const body = JSON.stringify({
      client_id: CODEX_OAUTH_CLIENT_ID,
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      scope: "openid profile email",
    });
    const raw = execSync(
      `/usr/bin/curl -fsS --max-time 8 -H "Content-Type: application/json" -d @- https://auth.openai.com/oauth/token`,
      {
        encoding: "utf8",
        timeout: 10000,
        input: body,
        stdio: ["pipe", "pipe", "ignore"],
      },
    );
    const r = JSON.parse(raw);
    if (!r?.access_token) return null;
    d.tokens = d.tokens || {};
    d.tokens.access_token = r.access_token;
    if (r.id_token) d.tokens.id_token = r.id_token;
    if (r.refresh_token) d.tokens.refresh_token = r.refresh_token;
    d.last_refresh = new Date().toISOString();
    writeFileSync(CODEX_AUTH, JSON.stringify(d, null, 2));
    return {
      accessToken: r.access_token,
      accountId: d.tokens.account_id || d.account_id || null,
    };
  } catch {
    return null;
  }
}

function normalizeCodexUsage(d) {
  const winFrom = (o, pctKey, resetKey) => {
    if (!o) return null;
    const pct = clampPct(o[pctKey] ?? o.used_percent ?? o.usedPercent);
    if (pct == null) return null;
    let resetsAt = null;
    const r = o[resetKey] ?? o.resets_at ?? o.resetsAt ?? o.reset_at;
    if (typeof r === "number" && Number.isFinite(r)) {
      resetsAt = r > 1e12 ? Math.floor(r / 1000) : Math.floor(r);
    } else if (typeof r === "string") {
      const t = Date.parse(r);
      if (Number.isFinite(t)) resetsAt = Math.floor(t / 1000);
    } else if (o.reset_after_seconds != null) {
      resetsAt = now + Number(o.reset_after_seconds);
    }
    return { pct, resetsAt };
  };
  const str = (v) => (v == null ? null : String(v));

  // shape A: /wham/usage
  const rl = d?.rate_limit || d?.rateLimit;
  if (rl?.primary_window || rl?.secondary_window) {
    return {
      fiveHour: winFrom(rl.primary_window, "used_percent"),
      weekly: winFrom(rl.secondary_window, "used_percent"),
      planType: d?.plan_type || d?.planType || rl?.plan_type || null,
      creditsBalance: str(d?.credits?.balance ?? rl?.credits?.balance),
    };
  }
  // shape B: rateLimits.primary / secondary
  const limits =
    d?.rateLimits || d?.rate_limits || d?.rateLimitsByLimitId?.codex;
  if (limits?.primary || limits?.secondary) {
    return {
      fiveHour: winFrom(limits.primary, "usedPercent"),
      weekly: winFrom(limits.secondary, "usedPercent"),
      planType: limits.planType || d?.planType || null,
      creditsBalance: str(limits?.credits?.balance),
    };
  }
  return { fiveHour: null, weekly: null, planType: null, creditsBalance: null };
}

function fetchCodexUsageLive() {
  const auth = readCodexAuth();
  if (!auth) return null;
  try {
    const request = (a) => {
      const headers = [
        `Authorization: Bearer ${a.accessToken}`,
        "User-Agent: ai-usage-for-mac",
        "Accept: application/json",
      ];
      if (a.accountId) headers.push(`ChatGPT-Account-Id: ${a.accountId}`);
      const raw = execSync(
        `/usr/bin/curl -sS --max-time 6 -H @- -w "\\n%{http_code}" "https://chatgpt.com/backend-api/wham/usage"`,
        {
          encoding: "utf8",
          timeout: 8000,
          input: headers.join("\n") + "\n",
          stdio: ["pipe", "pipe", "ignore"],
        },
      );
      const nl = raw.lastIndexOf("\n");
      return {
        status: Number(raw.slice(nl + 1).trim()),
        body: raw.slice(0, nl),
      };
    };

    let { status, body } = request(auth);
    if (status === 401) {
      // access_token 만료(10일 주기) → refresh 후 1회 재시도
      const refreshed = refreshCodexAuth();
      if (!refreshed) return null;
      ({ status, body } = request(refreshed));
    }
    if (status < 200 || status >= 300) return null;
    const norm = normalizeCodexUsage(JSON.parse(body));
    if (!norm.fiveHour && !norm.weekly) return null;
    const res = { ...norm, measuredAt: now, live: true };
    writeJSON(CODEX_USAGE_CACHE, res);
    return res;
  } catch {
    return null;
  }
}

function readCodexUsageFallback() {
  const c = readJSON(CODEX_USAGE_CACHE);
  if (c?.fiveHour || c?.weekly) return { ...c, live: false };
  return null;
}

function getCodexUsage() {
  return fetchCodexUsageLive() ?? readCodexUsageFallback();
}

// ── 출력 ─────────────────────────────────────────────
const errors = [];
const safe = (label, fn) => {
  try {
    return fn();
  } catch (e) {
    errors.push(`${label}: ${String(e?.message || e).split("\n")[0]}`);
    return null;
  }
};

const snapshot = {
  coreVersion: CORE_VERSION,
  now,
  exchangeRateKRW: safe("exchange", getExchangeRateKRW) ?? DEFAULT_KRW_RATE,
  claude: safe("claude", getClaudeUsage),
  claudeBlock: safe("claudeBlock", getClaudeBlock),
  claudeModels: safe("claudeModels", getClaudeModels),
  cursor: safe("cursor", getCursorUsage),
  codex: safe("codex", getCodexUsage),
  ccusage: !!CCUSAGE,
  errors,
};

process.stdout.write(JSON.stringify(snapshot));
