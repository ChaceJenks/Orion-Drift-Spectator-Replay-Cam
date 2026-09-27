--!strict
--[[
	Tests for the small helpers that everything else leans on.

	Two groups matter most. The path helpers decide whether a replay listed by the
	client and a replay named in a saved shot are recognised as the same file,
	because the two APIs report the same replay in different shapes. The time
	helpers decide whether a timestamp prints as something a person can read, and
	whether a generated file name is actually sortable and unique.
]]

local Harness = require("./harness")
local Util = require("../pkg/util")

Harness.suite("util")

---- Numbers ------------------------------------------------------------------

Harness.near(Util.clamp(5, 0, 10), 5, "a value inside the range is untouched")
Harness.near(Util.clamp(-1, 0, 10), 0, "below the range clamps to the floor")
Harness.near(Util.clamp(11, 0, 10), 10, "above the range clamps to the ceiling")
Harness.near(Util.clamp(0, 0, 0), 0, "a degenerate range still returns the value")

Harness.near(Util.lerp(0, 10, 0), 0, "lerp at 0 is a")
Harness.near(Util.lerp(0, 10, 1), 10, "lerp at 1 is b")
Harness.near(Util.lerp(0, 10, 0.25), 2.5, "lerp interpolates linearly")
Harness.near(Util.lerp(-4, 4, 0.5), 0, "lerp crosses zero")

Harness.check(Util.isFiniteNumber(1), "a plain number is finite")
Harness.check(not Util.isFiniteNumber(0 / 0), "NaN is not finite")
Harness.check(not Util.isFiniteNumber(math.huge), "infinity is not finite")
Harness.check(not Util.isFiniteNumber(-math.huge), "negative infinity is not finite")

do
	-- The integrator hands this a variable dt, including frame hitches.
	local settled = Util.exponentialSmoothing(0, 100, 0.5, 10)
	Harness.near(settled, 100, "a long dt closes almost the whole gap", 1e-6)
	local held = Util.exponentialSmoothing(42, 100, 0.5, 0)
	Harness.near(held, 100, "dt of 0 jumps straight to the target rather than dividing by zero")
	local instant = Util.exponentialSmoothing(42, 100, 0, 0.1)
	Harness.near(instant, 100, "a zero time constant means no smoothing")
	local step = Util.exponentialSmoothing(0, 100, 0.5, 0.5)
	Harness.check(step > 0 and step < 100, "a short dt moves part of the way")
end

---- Config coercion ----------------------------------------------------------

Harness.near(Util.num(7, 1, 0, 10), 7, "a number passes through")
Harness.near(Util.num("7.5", 1, 0, 10), 7.5, "a numeric string is parsed, not rejected")
Harness.near(Util.num(nil, 3), 3, "nil falls back to the default")
Harness.near(Util.num("not a number", 3), 3, "unparseable text falls back")
Harness.near(Util.num({}, 3), 3, "a table falls back")
Harness.near(Util.num(0, 3), 0, "zero is a real value, not an absent one")
Harness.near(Util.num(false, 3), 3, "false is not a number")
Harness.near(Util.num(999, 3, 0, 10), 10, "clamped from above")
Harness.near(Util.num(-999, 3, 0, 10), 0, "clamped from below")
Harness.near(Util.num(0 / 0, 3), 3, "NaN in a config file cannot poison the camera")

Harness.equal(Util.int("7.6", 1, 0, 100), 8, "int rounds to nearest rather than truncating")
Harness.equal(Util.int(2.4, 1), 2, "rounding goes down below .5")
Harness.equal(Util.int("nope", 9), 9, "junk falls back")

Harness.equal(Util.bool(true, false), true, "true passes through")
Harness.equal(Util.bool(false, true), false, "false is respected, not treated as absent")
Harness.equal(Util.bool(nil, true), true, "nil takes the default")
Harness.equal(Util.bool("true", false), false, "a string is not a boolean")
Harness.equal(Util.bool(1, false), false, "a number is not a boolean")

Harness.equal(Util.str("keep", "other"), "keep", "a string passes through")
Harness.equal(Util.str("", "other"), "other", "an empty string takes the default")
Harness.equal(Util.str(nil, "other"), "other", "nil takes the default")

Harness.equal(Util.enum("loop", { "loop", "stop" }, "stop"), "loop", "a known value is accepted")
Harness.equal(Util.enum("sideways", { "loop", "stop" }, "stop"), "stop", "an unknown value falls back")
Harness.equal(Util.enum(nil, { "loop" }, "loop"), "loop", "nil falls back")

do
	local config = { keep = "mine", empty = nil } :: { [string]: any }
	local missing = Util.applyDefaults(config, { keep = "theirs", added = 5, another = true })
	Harness.equal(config.keep, "mine", "an existing value is never overwritten")
	Harness.equal(config.added, 5, "a missing key is created")
	Harness.equal(config.another, true, "booleans are filled in too")
	Harness.equal(#missing, 2, "the report lists exactly what was missing")
	Harness.equal(missing[1], "added", "the missing list is sorted for a stable log line")
	Harness.equal(#Util.applyDefaults(nil :: any, { a = 1 }), 0, "a missing config table is survivable")
end

---- Time and stamps ----------------------------------------------------------

Harness.near(Util.ticksToSeconds(1e7), 1, "one second is ten million ticks")
Harness.near(Util.ticksToSeconds(0), 0, "zero ticks is zero seconds")
Harness.near(Util.ticksToSeconds(-1e7), -1, "negative ticks stay negative")
Harness.equal(Util.secondsToTicks(1), 1e7, "seconds convert back to ticks")
Harness.equal(Util.secondsToTicks(0.5), 5e6, "half a second")
Harness.equal(Util.secondsToTicks(1.2e-7), 1, "sub-tick values round rather than truncate")

Harness.equal(Util.formatTime(0), "00:00.00", "zero formats cleanly")
Harness.equal(Util.formatTime(65.5), "01:05.50", "a minute and a half")
Harness.equal(Util.formatTime(3599.99), "59:59.99", "under an hour stays in minutes")
Harness.equal(Util.formatTime(-3), "-00:03.00", "a negative time prints with a sign")
Harness.equal(Util.formatTime(0 / 0), "--:--", "NaN does not reach string.format")
Harness.equal(Util.formatTime(math.huge), "--:--", "neither does infinity")
Harness.equal(Util.formatTime(600), "10:00.00", "ten minutes")

do
	-- 2024-01-02T03:04:05Z, expressed the way the client does it: 100 ns ticks
	-- since 0001-01-01, which is 719162 days before the Unix epoch.
	local unixSeconds = 1704164645
	local ticks = (719162 * 86400 + unixSeconds) * 1e7
	Harness.equal(Util.stampFromTicks(ticks), "20240102-030405", "a known UTC instant stamps correctly")

	-- A leap day, because any date arithmetic is wrong somewhere if not here.
	local leapTicks = (719162 * 86400 + 1709251200) * 1e7 -- 2024-03-01T00:00:00Z
	Harness.equal(Util.stampFromTicks(leapTicks), "20240301-000000", "the day after a leap day")

	-- Before the epoch there is no useful date, so it degrades to a time of day
	-- rather than producing a nonsense year.
	local early = Util.stampFromTicks(1e7 * 3600)
	Harness.equal(#early, 6, "a pre-epoch stamp is still a printable name")
	Harness.check(tonumber(early) ~= nil, "and it is still only digits")
end

---- Paths --------------------------------------------------------------------

Harness.equal(Util.basename("match1.a2replay"), "match1.a2replay", "a bare name is unchanged")
Harness.equal(Util.basename("replays/match1.a2replay"), "match1.a2replay", "a unix path reduces to its name")
Harness.equal(Util.basename("C:\\Users\\me\\replays\\match1.a2replay"), "match1.a2replay", "a windows path too")
Harness.equal(Util.basename("a/b/c/d"), "d", "the last separator wins")
Harness.equal(Util.basename(""), "", "an empty path stays empty")

Harness.equal(Util.hasReplayExtension("match.a2replay"), true, "the extension is recognised")
Harness.equal(Util.hasReplayExtension("MATCH.A2REPLAY"), true, "and is case insensitive")
Harness.equal(Util.hasReplayExtension("match.json"), false, "other extensions are not replays")
Harness.equal(Util.hasReplayExtension(".a2replay"), true, "a bare extension still ends with it")

Harness.equal(Util.shortReplayName("C:\\x\\match1.a2replay"), "match1", "directories and extension are both stripped")
Harness.equal(Util.shortReplayName("match1"), "match1", "a short name is unchanged")
Harness.equal(Util.shortReplayName("match.tar.gz"), "match.tar.gz", "only the replay extension is stripped")

Harness.equal(Util.containsCaseless("Match_Final_3", "final"), true, "a substring match ignores case")
Harness.equal(Util.containsCaseless("Match_Final_3", "FINAL"), true, "in either direction")
Harness.equal(Util.containsCaseless("anything", ""), true, "an empty filter matches everything")
Harness.equal(Util.containsCaseless("match", "zzz"), false, "a non-match does not match")
Harness.equal(Util.containsCaseless("a.b", "a.b"), true, "dots are literal, not a pattern")

---- Errors and collections ---------------------------------------------------

Harness.equal(Util.errorText("boom"), "boom", "a string error passes through")
Harness.check(string.find(Util.errorText(42), "42", 1, true) ~= nil, "a number error is stringified")
Harness.check(#Util.errorText({}) > 0, "a table error still produces something printable")

do
	local value, err = Util.try(function()
		return 5
	end)
	Harness.equal(value, 5, "a successful call returns its value")
	Harness.isNil(err, "and no error")

	local bad, badError = Util.try(function()
		error("kaboom", 0)
	end)
	Harness.isNil(bad, "a thrown call returns nil")
	Harness.check(badError ~= nil and string.find(badError :: string, "kaboom", 1, true) ~= nil, "and reports the message")

	local indexed, indexError = Util.try(function()
		return (nil :: any).missing
	end)
	Harness.isNil(indexed, "a runtime fault is caught too")
	Harness.notNil(indexError, "with a message rather than a crash")
end

do
	local noticeValue, notice = Util.tryWith("loading", function()
		error("nope", 0)
	end)
	Harness.isNil(noticeValue, "tryWith yields no value on failure")
	Harness.notNil(notice, "tryWith yields a notice")
	if notice ~= nil then
		local ready = notice :: { kind: string, text: string }
		Harness.equal(ready.kind, "error", "the notice is an error")
		Harness.check(string.find(ready.text, "loading", 1, true) ~= nil, "and names the action that failed")
	end

	local okNotice, okError = Util.tryWith("loading", function()
		return "fine"
	end)
	Harness.equal(okNotice, "fine", "tryWith passes the value through on success")
	Harness.isNil(okError, "with no notice")
end

Harness.equal(Util.indexOf({ "a", "b", "c" }, "b"), 2, "index found")
Harness.isNil(Util.indexOf({ "a" }, "z"), "missing value has no index")
Harness.equal(Util.length({ 1, 2, 3 }), 3, "length counts a list")

local failures = Harness.report()
if failures > 0 then
	error(string.format("%d util checks failed", failures), 0)
end
