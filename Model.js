// Pure JS: weekly reset math, countdown label, affix/character parsing,
// weekly lockout and Great Vault counting. No QML or Qt types, so this stays
// testable under node.

var MAX_CHARACTERS = 12
var NAME_MAX = 24
var REALM_MAX = 40
var ERROR_MAX = 200
var MS_PER_MINUTE = 60000
var MS_PER_HOUR = 3600000
var MS_PER_DAY = 86400000
var MS_PER_WEEK = 7 * MS_PER_DAY

// Weekly reset, in UTC. Day is JS getUTCDay (0 = Sunday). US is Tuesday
// 15:00 UTC; EU Wednesday 04:00 UTC; KR/TW Wednesday 23:00 UTC (Thursday
// morning locally). These match the season start times Raider.io publishes.
var RESETS = {
  us: { day: 2, hour: 15, label: "US" },
  eu: { day: 3, hour: 4, label: "EU" },
  kr: { day: 3, hour: 23, label: "KR" },
  tw: { day: 3, hour: 23, label: "TW" }
}
var REGIONS = ["us", "eu", "kr", "tw"]

// Great Vault thresholds: dungeon runs, and raid bosses (any difficulty).
var VAULT_DUNGEON_STEPS = [1, 4, 8]
var VAULT_RAID_STEPS = [2, 4, 6]

// Bar icon: the default sword glyph, or a faction emblem the helper
// downloads once (Blizzard artwork is never bundled with the plugin).
var ICONS = ["sword", "horde", "alliance"]

function validIcon(value) {
  var icon = cleanText(value, 12).toLowerCase()
  return ICONS.indexOf(icon) >= 0 ? icon : "sword"
}

// Only an absolute path to emblem-<faction>.png inside the plugin's state
// directory is accepted from the helper.
function validEmblemPath(path, faction) {
  var text = String(path || "")
  if (faction !== "horde" && faction !== "alliance") return ""
  if (text.charAt(0) !== "/" || /[\x00-\x1f\x7f]/.test(text) || /(^|\/)\.\.?(\/|$)/.test(text)) return ""
  var suffix = "/.local/state/omarchy-wow-reset/emblem-" + faction + ".png"
  if (text.length <= suffix.length || text.substring(text.length - suffix.length) !== suffix) return ""
  return text
}

var DIFFICULTY_ORDER = ["LFR", "NORMAL", "HEROIC", "MYTHIC"]
var DIFFICULTY_SHORT = { LFR: "LFR", NORMAL: "N", HEROIC: "H", MYTHIC: "M" }

function cleanText(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/\u0000/g, "")
  text = text.replace(/[\u0001-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
  text = text.replace(/<[^>]*>/g, "")
  text = text.replace(/\s+/g, " ").replace(/^ | $/g, "")
  var max = Number(limit)
  if (!isFinite(max) || max <= 0) max = 200
  if (text.length > max) text = text.substring(0, max)
  return text
}

function conciseError(value, fallback) {
  var text = cleanText(value || fallback || "Request failed", ERROR_MAX)
  return text.length > 180 ? text.substring(0, 177) + "…" : text
}

function asInt(value) {
  var n = Number(value)
  return isFinite(n) ? Math.trunc(n) : 0
}

function validRegion(value) {
  var region = cleanText(value, 4).toLowerCase()
  return REGIONS.indexOf(region) >= 0 ? region : ""
}

function regionLabel(region) {
  var r = RESETS[validRegion(region)]
  return r ? r.label : "US"
}

// ---------------------------------------------------------------- Reset --

// The most recent reset at or before `nowMs`.
function lastResetMs(region, nowMs) {
  var spec = RESETS[validRegion(region)] || RESETS.us
  var now = Number(nowMs)
  if (!isFinite(now)) now = Date.now()
  var d = new Date(now)
  var candidate = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), spec.hour, 0, 0)
  candidate -= ((d.getUTCDay() - spec.day + 7) % 7) * MS_PER_DAY
  if (candidate > now) candidate -= MS_PER_WEEK
  return candidate
}

function nextResetMs(region, nowMs) {
  return lastResetMs(region, nowMs) + MS_PER_WEEK
}

// "3d 4h", "5h 12m", "42m", "<1m".
function countdownText(msLeft) {
  var ms = Math.max(0, Number(msLeft) || 0)
  var days = Math.floor(ms / MS_PER_DAY)
  var hours = Math.floor((ms % MS_PER_DAY) / MS_PER_HOUR)
  var minutes = Math.floor((ms % MS_PER_HOUR) / MS_PER_MINUTE)
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  if (minutes > 0) return minutes + "m"
  return "<1m"
}

function barLabel(region, nowMs) {
  return countdownText(nextResetMs(region, nowMs) - Number(nowMs))
}

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

function pad2(n) { return n < 10 ? "0" + n : String(n) }

// Local wall-clock time of the reset, e.g. "Tue 08:00". Uses the JS engine's
// local zone (the shell's), which is what the user sees on their clock.
function localResetText(region, nowMs) {
  var d = new Date(nextResetMs(region, nowMs))
  return WEEKDAYS[d.getDay()] + " " + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// ------------------------------------------------------------- Affixes --

function parseAffixes(raw) {
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.items)) return null
  var items = []
  for (var i = 0; i < raw.items.length && items.length < 8; i++) {
    var a = raw.items[i]
    if (!a || typeof a !== "object") continue
    var name = cleanText(a.name, 60)
    if (name === "") continue
    items.push({ id: asInt(a.id), name: name, description: cleanText(a.description, 240) })
  }
  return { region: validRegion(raw.region), title: cleanText(raw.title, 200), items: items }
}

// ---------------------------------------------------------- Characters --

function validName(value) {
  var name = cleanText(value, NAME_MAX)
  // Letters only, including accented ones; same rule as the helper.
  if (name.length < 2 || /[\s\d!-@\[-`{-~]/.test(name)) return ""
  return name
}

function validRealm(value) {
  var realm = cleanText(value, REALM_MAX)
  if (realm.length < 2 || /[!-&(-,.\/:-@\[-`{-~]/.test(realm)) return ""
  return realm
}

function realmSlug(realm) {
  return String(realm || "").toLowerCase().replace(/'/g, "").replace(/[\s-]+/g, "-").replace(/^-+|-+$/g, "")
}

function characterKey(c) {
  if (!c) return ""
  return validRegion(c.region) + "/" + realmSlug(c.realm) + "/" + String(c.name || "").toLowerCase()
}

function sanitizeCharacters(list) {
  var out = []
  var seen = {}
  var raw = Array.isArray(list) ? list : []
  for (var i = 0; i < raw.length && out.length < MAX_CHARACTERS; i++) {
    var c = raw[i]
    if (!c || typeof c !== "object") continue
    var entry = { region: validRegion(c.region), name: validName(c.name), realm: validRealm(c.realm) }
    if (!entry.region || !entry.name || !entry.realm) continue
    var key = characterKey(entry)
    if (seen[key]) continue
    seen[key] = true
    out.push(entry)
  }
  return out
}

function alreadyOnList(list, character) {
  var key = characterKey(character)
  var raw = Array.isArray(list) ? list : []
  for (var i = 0; i < raw.length; i++) if (characterKey(raw[i]) === key) return true
  return false
}

function withoutCharacter(list, character) {
  var key = characterKey(character)
  var raw = Array.isArray(list) ? list : []
  var out = []
  for (var i = 0; i < raw.length; i++) if (characterKey(raw[i]) !== key) out.push(raw[i])
  return out
}

function parseCharacterData(raw) {
  if (!raw || typeof raw !== "object") return null
  var base = { region: validRegion(raw.region), name: validName(raw.name), realm: validRealm(raw.realm) }
  if (!base.region || !base.name || !base.realm) return null
  if (raw.error) {
    base.error = conciseError(raw.error, "Could not refresh")
    return base
  }
  base.className = cleanText(raw.className, 24)
  base.spec = cleanText(raw.spec, 24)
  base.score = Number(raw.score) > 0 ? Math.round(Number(raw.score) * 10) / 10 : 0
  base.weeklyRuns = []
  var runs = Array.isArray(raw.weeklyRuns) ? raw.weeklyRuns : []
  for (var i = 0; i < runs.length && base.weeklyRuns.length < 10; i++) {
    var r = runs[i]
    if (!r || typeof r !== "object" || asInt(r.level) <= 0) continue
    base.weeklyRuns.push({
      dungeon: cleanText(r.dungeon, 40),
      short: cleanText(r.short, 8),
      level: asInt(r.level),
      timed: r.timed === true,
      completedAt: cleanText(r.completedAt, 32)
    })
  }
  base.progression = []
  var prog = Array.isArray(raw.progression) ? raw.progression : []
  for (var j = 0; j < prog.length && base.progression.length < 6; j++) {
    var p = prog[j]
    if (!p || typeof p !== "object") continue
    base.progression.push({ name: cleanText(p.name, 60), summary: cleanText(p.summary, 16), total: asInt(p.total) })
  }
  base.lockouts = null
  if (Array.isArray(raw.lockouts)) {
    base.lockouts = []
    for (var k = 0; k < raw.lockouts.length && base.lockouts.length < 6; k++) {
      var inst = raw.lockouts[k]
      if (!inst || typeof inst !== "object" || !Array.isArray(inst.modes)) continue
      var modes = []
      for (var m = 0; m < inst.modes.length && modes.length < 4; m++) {
        var mode = inst.modes[m]
        if (!mode || typeof mode !== "object") continue
        var bosses = []
        var list = Array.isArray(mode.bosses) ? mode.bosses : []
        for (var b = 0; b < list.length && bosses.length < 20; b++) {
          if (!list[b] || typeof list[b] !== "object") continue
          bosses.push({ name: cleanText(list[b].name, 60), lastKill: Math.max(0, Number(list[b].lastKill) || 0) })
        }
        var difficulty = cleanText(mode.difficulty, 16).toUpperCase()
        modes.push({
          difficulty: difficulty,
          label: cleanText(mode.label, 24) || difficulty,
          total: asInt(mode.total) > 0 ? asInt(mode.total) : bosses.length,
          bosses: bosses
        })
      }
      base.lockouts.push({ name: cleanText(inst.name, 60), modes: modes })
    }
  }
  if (raw.lockoutError) base.lockoutError = conciseError(raw.lockoutError, "")
  return base
}

// ------------------------------------------------------- Weekly counting --

function runsThisWeek(character, region, nowMs) {
  if (!character || !Array.isArray(character.weeklyRuns)) return []
  var since = lastResetMs(region || character.region, nowMs)
  var out = []
  for (var i = 0; i < character.weeklyRuns.length; i++) {
    var run = character.weeklyRuns[i]
    var t = Date.parse(run.completedAt)
    // Raider.io's weekly list is already this week; the date check drops a
    // stale crawl that straddles reset.
    if (!isFinite(t) || t >= since) out.push(run)
  }
  out.sort(function(a, b) { return b.level - a.level })
  return out
}

function vaultSlots(count, steps) {
  var n = 0
  for (var i = 0; i < steps.length; i++) if (count >= steps[i]) n++
  return n
}

// Per raid, per difficulty: bosses killed since reset. Also the number of
// distinct bosses killed this week on any difficulty (what the raid row of
// the Great Vault counts, taking the highest difficulty per boss).
function weeklyLockouts(character, nowMs) {
  if (!character || !Array.isArray(character.lockouts)) return null
  var since = lastResetMs(character.region, nowMs)
  var raids = []
  var distinct = {}
  for (var i = 0; i < character.lockouts.length; i++) {
    var inst = character.lockouts[i]
    var modes = []
    for (var m = 0; m < inst.modes.length; m++) {
      var mode = inst.modes[m]
      var killed = 0
      var names = []
      for (var b = 0; b < mode.bosses.length; b++) {
        if (mode.bosses[b].lastKill >= since) {
          killed++
          names.push(mode.bosses[b].name)
          distinct[inst.name + "/" + mode.bosses[b].name] = true
        }
      }
      if (killed > 0) modes.push({ difficulty: mode.difficulty, label: mode.label, killed: killed, total: mode.total, bosses: names })
    }
    modes.sort(function(a, b) { return DIFFICULTY_ORDER.indexOf(b.difficulty) - DIFFICULTY_ORDER.indexOf(a.difficulty) })
    raids.push({ name: inst.name, modes: modes })
  }
  return { raids: raids, bossesThisWeek: Object.keys(distinct).length }
}

// "H 3/8 · M 1/8", or "" when nothing is saved this week.
function lockoutSummary(raid) {
  if (!raid || !Array.isArray(raid.modes) || raid.modes.length === 0) return ""
  var bits = []
  for (var i = 0; i < raid.modes.length; i++) {
    var mode = raid.modes[i]
    bits.push((DIFFICULTY_SHORT[mode.difficulty] || mode.label) + " " + mode.killed + "/" + mode.total)
  }
  return bits.join(" · ")
}

function dungeonSummary(runs) {
  if (!runs || runs.length === 0) return "No Mythic+ runs this week"
  var levels = []
  for (var i = 0; i < runs.length && i < 8; i++) levels.push("+" + runs[i].level)
  var slots = vaultSlots(runs.length, VAULT_DUNGEON_STEPS)
  return runs.length + (runs.length === 1 ? " run" : " runs") + " · vault " + slots + "/3 · " + levels.join(" ")
}

// ------------------------------------------------------------ Ops output --

function parseOps(text) {
  var parsed
  try { parsed = JSON.parse(String(text || "")) } catch (e) {
    return { ok: false, error: conciseError(text, "Could not talk to the helper") }
  }
  if (!parsed || typeof parsed !== "object") return { ok: false, error: "Unexpected response" }
  if (parsed.ok !== true) return { ok: false, error: conciseError(parsed.error, "Request failed") }
  var characters = []
  if (Array.isArray(parsed.characters)) {
    for (var i = 0; i < parsed.characters.length && characters.length < MAX_CHARACTERS; i++) {
      var c = parseCharacterData(parsed.characters[i])
      if (c) characters.push(c)
    }
  }
  return {
    ok: true,
    error: parsed.error ? conciseError(parsed.error, "") : "",
    affixes: parseAffixes(parsed.affixes),
    characters: characters,
    character: parsed.character ? sanitizeCharacters([parsed.character])[0] || null : null,
    config: parsed.config && typeof parsed.config === "object" ? { characters: sanitizeCharacters(parsed.config.characters) } : null,
    blizzard: parsed.blizzard === true,
    emblem: parsed.emblem && typeof parsed.emblem === "object"
      && validEmblemPath(parsed.emblem.path, parsed.emblem.faction) !== ""
      ? { faction: parsed.emblem.faction, path: parsed.emblem.path } : null,
    fetchedAt: asInt(parsed.fetchedAt)
  }
}

// ---------------------------------------------------------------------------
// Process boundary. Nothing is resolved through the session PATH: the only
// interpreter ever started is one of these fixed absolute paths, probed in
// order at startup, and every job runs under bin/bounded-run with a cleared
// environment. If none of them exists the widget refuses to run anything.
// ---------------------------------------------------------------------------

var PYTHON_CANDIDATES = ["/usr/bin/python3", "/bin/python3", "/run/current-system/sw/bin/python3"]
var TRUSTED_PATH = "/usr/bin:/bin:/run/current-system/sw/bin"
var PYTHON_FLAGS = ["-I", "-S", "-B"]
var KILL_GRACE_SECONDS = 2

// Per job: stdout cap, stderr cap, deadline (seconds). A character refresh
// makes up to two Raider.io and one Blizzard call per character.
var JOB_LIMITS = {
  load: [65536, 16384, 15],
  save: [4096, 16384, 15],
  affixes: [65536, 65536, 45],
  lookup: [16384, 65536, 45],
  characters: [524288, 65536, 300],
  set_blizzard: [4096, 65536, 45],
  clear_blizzard: [4096, 16384, 15],
  emblem: [4096, 16384, 60]
}

function processEnvironment() {
  return { PATH: TRUSTED_PATH, LC_ALL: "C.UTF-8" }
}

function trustedPython(path) {
  var text = String(path || "")
  return PYTHON_CANDIDATES.indexOf(text) >= 0 ? text : ""
}

function validPluginDir(path) {
  var text = String(path || "")
  if (text.charAt(0) !== "/" || /[\x00-\x1f\x7f]/.test(text) || /(^|\/)\.\.?(\/|$)/.test(text)) return ""
  return text
}

function pythonProbeCommand(candidate) {
  var python = trustedPython(candidate)
  if (python === "") return []
  return [python].concat(PYTHON_FLAGS, ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 3)"])
}

// `kind` is one of JOB_LIMITS. Returns [] (a Process given [] starts nothing)
// unless the interpreter is a probed trusted candidate.
function helperCommand(python, pluginDir, kind) {
  var interpreter = trustedPython(python)
  var dir = validPluginDir(pluginDir)
  var limits = JOB_LIMITS[kind]
  if (interpreter === "" || dir === "" || !limits) return []
  return [interpreter].concat(PYTHON_FLAGS, [dir + "/bin/bounded-run",
    "--stdout-cap", String(limits[0]), "--stderr-cap", String(limits[1]),
    "--deadline", String(limits[2]), "--grace", String(KILL_GRACE_SECONDS),
    "--", interpreter], PYTHON_FLAGS, [dir + "/bin/wow-reset-ops"])
}

// Supervisor exit codes (bin/bounded-run) → a message, or "" for the job's
// own status.
function jobFailure(exitCode, what) {
  var subject = what || "Raider.io"
  if (exitCode === 124) return subject + " took too long to answer"
  if (exitCode === 201) return subject + " sent more data than expected"
  if (exitCode === 202) return subject + " error output was truncated"
  if (exitCode >= 125 && exitCode <= 127) return "Could not start the WoW Reset helper"
  return ""
}
