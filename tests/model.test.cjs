#!/usr/bin/env node
"use strict";
// Model: reset math, countdown, weekly lockouts and vault counting, output
// parsing, and the process boundary (argv shape, closed environment, a
// hostile PATH/PYTHONPATH not reaching the helper). Offline.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const { spawnSync } = require("node:child_process");

const root = path.join(__dirname, "..");
const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(root, "Model.js"), "utf8"), model);

const H = 3600000;
const D = 24 * H;
const utc = (y, mo, d, h, mi) => Date.UTC(y, mo - 1, d, h, mi || 0);

// ---------------------------------------------------------------- Reset --
// 2026-09-15 is a Tuesday.
const usReset = utc(2026, 9, 15, 15);
const euReset = utc(2026, 9, 16, 4);
const krReset = utc(2026, 9, 16, 23);

assert.equal(model.lastResetMs("us", utc(2026, 9, 17, 12)), usReset);
assert.equal(model.nextResetMs("us", utc(2026, 9, 17, 12)), usReset + 7 * D);
// Exactly at reset, the new week has started.
assert.equal(model.lastResetMs("us", usReset), usReset);
assert.equal(model.lastResetMs("us", usReset - 1), usReset - 7 * D);
assert.equal(model.nextResetMs("us", usReset - 60000), usReset);
// Tuesday before 15:00 UTC still belongs to last week; Monday too.
assert.equal(model.nextResetMs("us", utc(2026, 9, 15, 9)), usReset);
assert.equal(model.nextResetMs("us", utc(2026, 9, 14, 23)), usReset);
// EU on Tuesday evening is still waiting for Wednesday 04:00.
assert.equal(model.nextResetMs("eu", utc(2026, 9, 15, 20)), euReset);
assert.equal(model.lastResetMs("eu", utc(2026, 9, 16, 5)), euReset);
assert.equal(model.nextResetMs("kr", utc(2026, 9, 16, 22)), krReset);
assert.equal(model.nextResetMs("tw", utc(2026, 9, 16, 22)), krReset);
// Unknown region falls back to US; month and year boundaries hold.
assert.equal(model.nextResetMs("mars", utc(2026, 9, 17, 12)), usReset + 7 * D);
assert.equal(model.nextResetMs("us", utc(2026, 12, 31, 12)), utc(2027, 1, 5, 15));
assert.equal(new Date(model.nextResetMs("eu", utc(2027, 2, 28, 12))).getUTCDay(), 3);
// Every week of a year lands on the right weekday and hour.
for (let t = utc(2026, 1, 1, 0); t < utc(2027, 1, 1, 0); t += 13 * H) {
  const n = new Date(model.nextResetMs("us", t));
  assert.equal(n.getUTCDay(), 2);
  assert.equal(n.getUTCHours(), 15);
  assert.ok(n.getTime() > t && n.getTime() <= t + 7 * D);
}

assert.equal(model.countdownText(3 * D + 4 * H + 59 * 60000), "3d 4h");
assert.equal(model.countdownText(5 * H + 12 * 60000), "5h 12m");
assert.equal(model.countdownText(42 * 60000 + 5000), "42m");
assert.equal(model.countdownText(30000), "<1m");
assert.equal(model.countdownText(-5), "<1m");
assert.equal(model.barLabel("us", usReset - (2 * D + 3 * H)), "2d 3h");
assert.equal(model.regionLabel("eu"), "EU");
assert.match(model.localResetText("us", utc(2026, 9, 17, 12)), /^(Mon|Tue|Wed) \d\d:\d\d$/);

// ------------------------------------------------------------ Parsing --
const helperOutput = {
  ok: true,
  characters: [{
    region: "us", name: "Examplemonk", realm: "Area 52", className: "Monk", spec: "<i>Brewmaster</i>", score: 3924.34,
    weeklyRuns: [
      { dungeon: "Murder Row", short: "MR", level: 12, timed: true, completedAt: "2026-09-15T17:13:07.000Z" },
      { dungeon: "Kings' Rest", short: "KR", level: 14, timed: false, completedAt: "2026-09-16T17:13:07.000Z" },
      { dungeon: "Old", short: "OLD", level: 20, timed: true, completedAt: "2026-09-14T17:13:07.000Z" },
      { dungeon: "Bad", level: 0 }
    ],
    progression: [{ name: "The Venomous Abyss", summary: "5/8 M", total: 8 }],
    lockouts: [{
      name: "The Venomous Abyss",
      modes: [
        { difficulty: "HEROIC", label: "Heroic", total: 8, bosses: [
          { name: "Boss One", lastKill: usReset + H },
          { name: "Boss Two", lastKill: usReset + 2 * H },
          { name: "Boss Three", lastKill: usReset - H }] },
        { difficulty: "MYTHIC", label: "Mythic", total: 8, bosses: [
          { name: "Boss One", lastKill: usReset + 3 * H },
          { name: "Boss Four", lastKill: usReset - 3 * D }] }
      ]
    }]
  }, { region: "eu", name: "Gone", realm: "Silvermoon", error: "Raider.io HTTP 400" },
     { region: "xx", name: "Nope", realm: "Realm" }],
  error: ""
};
const parsed = model.parseOps(JSON.stringify(helperOutput));
assert.equal(parsed.ok, true);
assert.equal(parsed.characters.length, 2);
const xae = parsed.characters[0];
assert.equal(xae.spec, "Brewmaster");
assert.equal(xae.score, 3924.3);
assert.equal(xae.weeklyRuns.length, 3);
assert.equal(parsed.characters[1].error, "Raider.io HTTP 400");

const now = utc(2026, 9, 17, 12);
const runs = model.runsThisWeek(xae, "us", now);
assert.deepEqual(Array.from(runs, (r) => r.level), [14, 12]);
assert.equal(model.dungeonSummary(runs), "2 runs · vault 1/3 · +14 +12");
assert.equal(model.dungeonSummary([]), "No Mythic+ runs this week");
assert.equal(model.vaultSlots(0, model.VAULT_DUNGEON_STEPS), 0);
assert.equal(model.vaultSlots(4, model.VAULT_DUNGEON_STEPS), 2);
assert.equal(model.vaultSlots(9, model.VAULT_DUNGEON_STEPS), 3);
assert.equal(model.vaultSlots(5, model.VAULT_RAID_STEPS), 2);

const weekly = model.weeklyLockouts(xae, now);
assert.equal(weekly.raids.length, 1);
// Mythic listed before Heroic; Boss One on both difficulties counts once.
assert.equal(model.lockoutSummary(weekly.raids[0]), "M 1/8 · H 2/8");
assert.equal(weekly.bossesThisWeek, 2);
assert.deepEqual(Array.from(weekly.raids[0].modes[1].bosses), ["Boss One", "Boss Two"]);
// After the next reset, the same data is a clean week.
const nextWeek = model.weeklyLockouts(xae, usReset + 7 * D + H);
assert.equal(model.lockoutSummary(nextWeek.raids[0]), "");
assert.equal(nextWeek.bossesThisWeek, 0);
// Raider.io only (no Blizzard credentials): no lockout block at all.
assert.equal(model.weeklyLockouts({ region: "us", lockouts: null }, now), null);

assert.equal(model.parseOps('{"ok":false,"error":"<b>nope</b>"}').error, "nope");
assert.equal(model.parseOps("not json").ok, false);
const loaded = model.parseOps(JSON.stringify({ ok: true, blizzard: true, config: { characters: [
  { region: "us", name: "Examplemonk", realm: "Area 52" }, { region: "us", name: "examplemonk", realm: "area-52" },
  { region: "us", name: "Bad1", realm: "x/y" }] } }));
assert.equal(loaded.blizzard, true);
assert.equal(loaded.config.characters.length, 1);
const affixes = model.parseOps(fs.readFileSync(path.join(root, "tests/fixtures/affixes-us.json"), "utf8"));
assert.equal(affixes.ok, false); // raw Raider.io JSON is not helper output
const affixOut = model.parseAffixes({ region: "eu", title: "t", items: [{ id: 9, name: "Tyrannical", description: "<b>x</b>" }, {}] });
assert.deepEqual(JSON.parse(JSON.stringify(affixOut)), { region: "eu", title: "t", items: [{ id: 9, name: "Tyrannical", description: "x" }] });

// Bar icon setting and emblem paths from the helper.
assert.equal(model.validIcon("Horde"), "horde");
assert.equal(model.validIcon("ALLIANCE"), "alliance");
assert.equal(model.validIcon("Sword"), "sword");
assert.equal(model.validIcon("pirate"), "sword");
assert.equal(model.validIcon(undefined), "sword");
const emblemPath = "/home/u/.local/state/omarchy-wow-reset/emblem-horde.png";
assert.equal(model.validEmblemPath(emblemPath, "horde"), emblemPath);
assert.equal(model.validEmblemPath(emblemPath, "alliance"), "");
assert.equal(model.validEmblemPath("relative/.local/state/omarchy-wow-reset/emblem-horde.png", "horde"), "");
assert.equal(model.validEmblemPath("/home/u/../../etc/.local/state/omarchy-wow-reset/emblem-horde.png", "horde"), "");
assert.equal(model.validEmblemPath("/etc/passwd", "horde"), "");
assert.equal(model.validEmblemPath("/.local/state/omarchy-wow-reset/emblem-horde.png\n", "horde"), "");
assert.deepEqual(JSON.parse(JSON.stringify(model.parseOps(JSON.stringify({ ok: true, emblem: { faction: "horde", path: emblemPath } })).emblem)),
  { faction: "horde", path: emblemPath });
assert.equal(model.parseOps(JSON.stringify({ ok: true, emblem: { faction: "horde", path: "/tmp/evil.png" } })).emblem, null);
assert.deepEqual(Array.from(model.helperCommand("/usr/bin/python3", root, "emblem")).slice(-1), [root + "/bin/wow-reset-ops"]);

// Character list helpers.
const list = model.sanitizeCharacters([{ region: "us", name: "Examplemonk", realm: "Area 52" }]);
assert.equal(model.alreadyOnList(list, { region: "us", name: "EXAMPLEMONK", realm: "area-52" }), true);
assert.equal(model.alreadyOnList(list, { region: "eu", name: "Examplemonk", realm: "Area 52" }), false);
assert.equal(model.withoutCharacter(list, { region: "us", name: "examplemonk", realm: "Area 52" }).length, 0);
assert.equal(model.validName("Ñoño"), "Ñoño");
assert.equal(model.validName("a b"), "");
assert.equal(model.validRealm("Area 52"), "Area 52");
assert.equal(model.validRealm("../x"), "");

// ---------------------------------------------------- Process boundary --
const env = model.processEnvironment();
assert.deepEqual(Object.keys(env).sort(), ["LC_ALL", "PATH"]);
for (const dir of env.PATH.split(":")) assert.ok(["/usr/bin", "/bin", "/run/current-system/sw/bin"].includes(dir), dir);

assert.deepEqual(Array.from(model.helperCommand("python3", root, "load")), []);
assert.deepEqual(Array.from(model.helperCommand("/tmp/python3", root, "load")), []);
assert.deepEqual(Array.from(model.helperCommand("/usr/bin/python3", "relative", "load")), []);
assert.deepEqual(Array.from(model.helperCommand("/usr/bin/python3", root + "/../x", "load")), []);
assert.deepEqual(Array.from(model.helperCommand("/usr/bin/python3", root, "shell")), []);
const argv = Array.from(model.helperCommand("/usr/bin/python3", root, "characters"));
assert.equal(argv[0], "/usr/bin/python3");
assert.equal(argv[argv.length - 1], root + "/bin/wow-reset-ops");
assert.ok(argv.includes(root + "/bin/bounded-run"));
assert.equal(argv[argv.indexOf("--deadline") + 1], "300");
assert.equal(model.jobFailure(124, "Raider.io"), "Raider.io took too long to answer");
assert.equal(model.jobFailure(0, "Raider.io"), "");

// A hostile PATH and PYTHONPATH must not reach the helper: run the exact
// argv the shell would, with the environment the shell passes, while a
// poisoned json.py sits in a directory the attacker controls.
const python = model.PYTHON_CANDIDATES.find((p) => fs.existsSync(p));
if (python) {
  const hostile = fs.mkdtempSync(path.join(os.tmpdir(), "wow-reset-shadow-"));
  const marker = path.join(hostile, "ran");
  fs.writeFileSync(path.join(hostile, "json.py"), `open(${JSON.stringify(marker)}, "a").write("json shadow\\n")\n`);
  fs.writeFileSync(path.join(hostile, "python3"), `#!/bin/sh\necho shadow >> ${JSON.stringify(marker)}\n`, { mode: 0o755 });
  const cmd = Array.from(model.helperCommand(python, root, "load"));
  const result = spawnSync(cmd[0], cmd.slice(1), {
    input: JSON.stringify({ op: "nope" }),
    env: Object.assign({ PYTHONPATH: hostile, PATH: hostile + ":/usr/bin:/bin", BASH_ENV: path.join(hostile, "x") }, env),
    cwd: hostile,
    timeout: 30000
  });
  const out = JSON.parse(String(result.stdout));
  assert.equal(out.error, "Unknown operation");
  assert.equal(fs.existsSync(marker), false, "hostile environment reached the helper");
  fs.rmSync(hostile, { recursive: true, force: true });
}

console.log("model tests passed");
