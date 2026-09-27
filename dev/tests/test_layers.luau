--!strict
--[[
	Tests for the multi-replay master clock. These are the tests that matter most,
	because "three replays play in lockstep" is the headline behaviour and it is
	entirely decided by the arithmetic in replaylayers.luau.
]]

local Harness = require("./harness")
local Layers = require("../pkg/replaylayers")
local Types = require("../pkg/types")

type Layer = Types.Layer
type ReplayHandle = Types.ReplayHandle

Harness.suite("replaylayers")

---- Fake replay handle --------------------------------------------------------
-- Implements exactly the ReplayHandle shape, recording every call so the tests
-- can assert what the client would have been told to do.

type Fake = ReplayHandle & {
	_setTimes: { number },
	_setPlaying: { boolean },
	_duration: number,
	_ticks: number,
}

local function fakeReplay(duration: number, startTicks: number): Fake
	local handle: Fake = {
		isPlaying = false,
		_setTimes = {},
		_setPlaying = {},
		_duration = duration,
		_ticks = startTicks,
		setPlaybackTimeSeconds = function(self: ReplayHandle, seconds: number)
			local fake = self :: any
			table.insert(fake._setTimes, seconds)
		end,
		getDurationSeconds = function(self: ReplayHandle): number
			return (self :: any)._duration
		end,
		getStartTime = function(self: ReplayHandle): Types.DateTimeStruct
			return { ticks = (self :: any)._ticks }
		end,
	}
	return handle
end

local function layerFor(file: string, duration: number, startTicks: number): Layer
	local layer = Layers.newLayer(file, "", duration, startTicks)
	layer.handle = fakeReplay(duration, startTicks)
	return layer
end

local TICK = 1e7

---- layerTime ----------------------------------------------------------------

do
	local held = Layers.newLayer("a.a2replay", "", 10, 0)

	Harness.near(Layers.layerTime(held, 5) or -1, 5, "inside the range passes through")
	Harness.near(Layers.layerTime(held, 0) or -1, 0, "t=0 maps to the first frame")
	Harness.near(Layers.layerTime(held, -3) or -1, 0, "hold clamps below zero to the first frame")
	Harness.near(Layers.layerTime(held, 42) or -1, 10, "hold clamps past the end to the last frame")

	local zero = Layers.newLayer("empty", "", 0, 0)
	Harness.isNil(Layers.layerTime(zero, 1), "a zero-duration layer is never driven")

	local looping = Layers.newLayer("b.a2replay", "", 10, 0)
	looping.overflow = "loop"
	Harness.near(Layers.layerTime(looping, 12) or -1, 2, "loop wraps past the end")
	Harness.near(Layers.layerTime(looping, -3) or -1, 7, "loop wraps before the start without going negative")
	Harness.near(Layers.layerTime(looping, 10) or -1, 10, "exactly at the duration gives the last frame, not a wrap to the first")
	Harness.check((Layers.layerTime(looping, -3) or -1) >= 0, "looped time is never negative")
end

---- Offsets ------------------------------------------------------------------

do
	local early = layerFor("early.a2replay", 20, 100 * TICK)
	local late = layerFor("late.a2replay", 20, 110 * TICK)
	late.offset = -10

	-- A layer offset by -10 is ten seconds behind the clock.
	Harness.near(Layers.layerTime(late, 10) or -1, 0, "offset -10 puts the layer on its first frame at t=10")
	Harness.near(Layers.layerTime(early, 10) or -1, 10, "the unoffset layer is 10 s in at the same clock")

	local start, finish = Layers.naturalWindow({ early, late })
	Harness.near(start, 0, "the window covers every layer, starting with the one visible first")
	Harness.near(finish, 30, "and runs to the last frame of the last one")
end

---- Wallclock alignment ------------------------------------------------------

do
	-- Three replays from one server session, recorded 5 s apart.
	local a = layerFor("a", 60, 1_000 * TICK)
	local b = layerFor("b", 60, 1_005 * TICK)
	local c = layerFor("c", 60, 1_010 * TICK)
	local layers = { b, a, c }

	local anchor = Layers.alignToWallclock(layers)
	Harness.near(anchor, 1_000 * TICK, "the anchor is the earliest recorded start")

	local byName: { [string]: Layer } = { a = a, b = b, c = c }
	Harness.near(byName["a"].offset, 0, "the earliest replay sits at offset 0")
	Harness.near(byName["b"].offset, -5, "a replay recorded 5 s later is held back 5 s")
	Harness.near(byName["c"].offset, -10, "a replay recorded 10 s later is held back 10 s")

	-- t=0 is the first recording's start. It is on its first frame, and the
	-- replays that had not started yet hold their own first frame instead of
	-- being driven to a negative time.
	Harness.near(Layers.layerTime(byName["a"], 0) or -1, 0, "the earliest replay is on its first frame at t=0")
	Harness.near(Layers.layerTime(byName["c"], 0) or -1, 0, "a not-yet-started replay holds its first frame")
	Harness.check((Layers.layerTime(byName["c"], 0) or 1) >= 0, "a held layer is never driven to a negative time")

	-- Once all three are live they sit 5 s apart in their own recordings, which is
	-- exactly the gap between their starts: the same wall-clock instant.
	Harness.near(Layers.layerTime(byName["a"], 20) or -1, 20, "at t=20 the earliest replay is 20 s in")
	Harness.near(Layers.layerTime(byName["b"], 20) or -1, 15, "the second replay is 5 s behind it")
	Harness.near(Layers.layerTime(byName["c"], 20) or -1, 10, "the third is 10 s behind")

	local start, finish = Layers.naturalWindow(layers)
	Harness.near(start, 0, "anchoring on the earliest start keeps the window at or after t=0")
	Harness.near(finish, 70, "and it runs until the last frame of the last-started replay")

	-- Alignment must be idempotent and independent of layer order.
	local secondPass = Layers.alignToWallclock(layers)
	Harness.near(secondPass, anchor, "re-aligning produces the same anchor")
	Harness.near(byName["a"].offset, 0, "re-aligning does not accumulate offsets")
	Harness.near(byName["c"].offset, -10, "re-aligning leaves the later layers where they belong")
end

do
	-- The crisp statement of what alignment means: for any two layers that are
	-- both live, the difference between their local replay times must equal the
	-- difference between their recorded start times. If that holds, both files are
	-- showing the same wall-clock instant, which is the entire feature.
	local early = layerFor("early", 100, 500 * TICK)
	local late = layerFor("late", 100, 537.25 * TICK) -- 37.25 s later than `early`
	Layers.alignToWallclock({ early, late })

	for _, masterT in { 60, 75, 90, 137.25 } do
		local timeEarly = Layers.layerTime(early, masterT)
		local timeLate = Layers.layerTime(late, masterT)
		if timeEarly ~= nil and timeLate ~= nil then
			-- Only meaningful while both are inside their own recording, not held
			-- or wrapped at an end.
			if timeEarly > 0 and timeEarly < 100 and timeLate > 0 and timeLate < 100 then
				Harness.near(
					timeEarly - timeLate,
					37.25,
					string.format("both layers show the same instant at masterT %.2f", masterT),
					1e-9
				)
			end
		end
	end
end

do
	-- A replay recorded just before midnight and one just after must still align:
	-- ticks are absolute, so there is no calendar edge to get wrong, but a
	-- hand-rolled "seconds of day" approach would have broken here.
	local midnight = 638_000_000_000_000_000
	local before = layerFor("before", 30, midnight - 2 * TICK)
	local after = layerFor("after", 30, midnight + 3 * TICK)
	Layers.alignToWallclock({ before, after })
	Harness.near(before.offset, 0, "the pre-midnight replay anchors at 0")
	Harness.near(after.offset, -5, "the cross-midnight gap measures 5 s, with no wrap-around")
end

do
	local noTimestamps = { Layers.newLayer("x", "", 10, 0) }
	local anchor = Layers.alignToWallclock(noTimestamps)
	Harness.near(anchor, 0, "no usable timestamps leaves the anchor at 0")
	Harness.near(noTimestamps[1].offset, 0, "and the offset stays at 0 rather than going negative-huge")
end

---- Advance: loop / stop / holdEnd -------------------------------------------

local function playingComp(loopMode: string): Types.Composition
	local comp = Layers.newComposition()
	comp.loopMode = loopMode
	comp.playing = true
	return comp
end

do
	local layers = { layerFor("a", 10, 0) }
	local comp = playingComp("loop")
	comp.masterT = 8
	for _ = 1, 40 do
		Layers.advance(comp, layers, 0.5)
	end
	Harness.check(comp.masterT >= 0 and comp.masterT <= 10, "looping keeps the clock inside the window")
	Harness.check(comp.playing, "looping never stops playback")
end

do
	local layers = { layerFor("a", 10, 0) }
	local comp = playingComp("loop")
	comp.masterT = 1
	for _ = 1, 4 do
		comp.speed = -1
		Layers.advance(comp, layers, 1)
	end
	Harness.check(comp.masterT >= 0 and comp.masterT <= 10, "reverse playback wraps at the start, not below zero")
end

do
	local layers = { layerFor("a", 10, 0) }
	local comp = playingComp("stop")
	comp.masterT = 9
	local notice = Layers.advance(comp, layers, 5)
	Harness.near(comp.masterT, 10, "stop clamps at the end")
	Harness.equal(comp.playing, false, "stop pauses the clock")
	Harness.notNil(notice, "stop reports why it paused")
end

do
	local layers = { layerFor("a", 10, 0) }
	local comp = playingComp("holdEnd")
	comp.masterT = 9
	Layers.advance(comp, layers, 5)
	Harness.near(comp.masterT, 10, "holdEnd clamps at the end")
	Harness.check(comp.playing, "holdEnd keeps the clock running so a camera path can finish")
end

do
	local comp = playingComp("loop")
	comp.speed = 0
	local layers = { layerFor("a", 10, 0) }
	comp.masterT = 3
	Layers.advance(comp, layers, 1)
	Harness.near(comp.masterT, 3, "speed 0 freezes the clock without stopping it")
end

do
	local comp = playingComp("loop")
	local notice = Layers.advance(comp, {}, 1)
	Harness.notNil(notice, "an empty composition explains itself instead of dividing by zero")
	Harness.equal(comp.playing, false, "an empty composition stops playback")
end

do
	local comp = playingComp("loop")
	Layers.advance(comp, { layerFor("a", 10, 0) }, -1)
	Harness.near(comp.masterT, 0, "a negative dt is ignored rather than rewinding the clock")
end

---- syncToClock: the lockstep guarantee --------------------------------------

do
	local a = layerFor("a", 30, 100 * TICK)
	local b = layerFor("b", 30, 105 * TICK)
	local c = layerFor("c", 30, 110 * TICK)
	local layers = { a, b, c }
	Layers.alignToWallclock(layers)

	local comp = Layers.newComposition()
	-- 20 s in is past the point where all three are live, so this checks real
	-- lockstep rather than three layers sitting on a held first frame.
	comp.masterT = 20
	local notices = Layers.syncToClock(comp, layers)
	Harness.equal(#notices, 0, "syncing three healthy layers produces no errors")

	-- Every layer must have been told its exact aligned time, in one pass. The
	-- 5 s spacing is the gap between when the recordings started.
	local fakeA = a.handle :: any
	local fakeB = b.handle :: any
	local fakeC = c.handle :: any
	Harness.near(fakeA._setTimes[1], 20, "layer A received its aligned time")
	Harness.near(fakeB._setTimes[1], 15, "layer B stays 5 s behind A")
	Harness.near(fakeC._setTimes[1], 10, "layer C stays 10 s behind A")

	-- And one second later they must still be 5 s apart: they advanced together.
	comp.masterT = 21
	Layers.syncToClock(comp, layers)
	Harness.near(fakeA._setTimes[2], 21, "A advanced with the clock")
	Harness.near(fakeB._setTimes[2], 16, "B advanced with the clock")
	Harness.near(fakeC._setTimes[2], 11, "C advanced with the clock")

	-- And crucially the client must not be left advancing them on its own: two
	-- syncs produced exactly two writes per layer, no more.
	Harness.equal(#fakeA._setTimes, 2, "each sync writes exactly one time per layer")
	local trio: { { name: string, layer: Layer } } = {
		{ name = "A", layer = a },
		{ name = "B", layer = b },
		{ name = "C", layer = c },
	}
	for _, entry in trio do
		local handle = entry.layer.handle
		Harness.notNil(handle, "layer " .. entry.name .. " still holds its handle after sync")
		if handle ~= nil then
			Harness.equal(handle.isPlaying, false, "isPlaying cleared on layer " .. entry.name)
		end
	end
end

do
	-- A handle that throws must not take the other layers with it.
	local broken = fakeReplay(10, 0)
	local brokenAny = broken :: any
	brokenAny.setPlaybackTimeSeconds = function()
		error("replay handle exploded", 0)
	end
	local good = layerFor("good", 10, 0)
	local badLayer = Layers.newLayer("bad", "", 10, 0)
	badLayer.handle = broken
	local comp = Layers.newComposition()
	local notices = Layers.syncToClock(comp, { badLayer, good })
	Harness.check(#notices >= 1, "a throwing handle produces a notice")
	Harness.equal(badLayer.missing, true, "the broken layer is marked missing")
	Harness.isNil(badLayer.handle, "the broken handle is dropped so it cannot spam every frame")
	Harness.equal(#((good.handle :: any)._setTimes), 1, "the healthy layer still got driven")
end

do
	-- independent mode hands control back rather than driving times.
	local a = layerFor("a", 10, 0)
	local comp = Layers.newComposition()
	comp.syncMode = "independent"
	comp.playing = true
	comp.masterT = 5
	Layers.syncToClock(comp, { a })
	Harness.equal(#((a.handle :: any)._setTimes), 0, "independent mode does not write playback times")
	Harness.equal((a.handle :: any).isPlaying, true, "independent mode passes the play flag through")
end

---- Handle reconciliation ----------------------------------------------------

do
	local a = Layers.newLayer("match1.a2replay", "", 10, 0)
	local b = Layers.newLayer("match2.a2replay", "", 10, 0)
	local layers = { a, b }

	-- First pass: only match1 is loaded, and it is reported with a directory
	-- prefix, which is how Replay.listLoaded() differs from Replay.listAll().
	local first: { [string]: ReplayHandle } = { ["match1.a2replay"] = fakeReplay(10, 0) }
	local noticesA = Layers.reconcile(layers, first)
	Harness.equal(a.missing, false, "match1 resolved its handle")
	Harness.equal(b.missing, true, "match2 is missing when it is not loaded")
	Harness.equal(#noticesA, 0, "a never-loaded layer does not raise a warning")

	-- Second pass: match1 was unloaded from the Replays panel.
	local second: { [string]: ReplayHandle } = {}
	local noticesB = Layers.reconcile(layers, second)
	Harness.equal(a.missing, true, "a layer loses its handle when the file is unloaded")
	Harness.equal(#noticesB, 1, "losing a handle raises exactly one warning")

	-- Third pass: it comes back (hot reload / user reloads the file).
	local third: { [string]: ReplayHandle } = { ["match1.a2replay"] = fakeReplay(10, 0) }
	local noticesC = Layers.reconcile(layers, third)
	Harness.equal(a.missing, false, "the handle is recovered when the file returns")
	Harness.equal(#noticesC, 1, "recovery is reported once")
end

---- Range, window, sanitisation ----------------------------------------------

do
	local layers = { layerFor("a", 60, 0) }
	local comp = Layers.newComposition()
	comp.rangeStart = 10
	comp.rangeEnd = 20
	local start, finish = Layers.effectiveWindow(comp, layers)
	Harness.near(start, 10, "a user range clips the start")
	Harness.near(finish, 20, "a user range clips the end")

	comp.rangeEnd = 0
	start, finish = Layers.effectiveWindow(comp, layers)
	Harness.near(start, 0, "an unset range falls back to the natural window")
	Harness.near(finish, 60, "an unset range covers the whole replay")

	comp.rangeStart = 40
	comp.rangeEnd = 10
	start, finish = Layers.effectiveWindow(comp, layers)
	Harness.near(start, 0, "an inverted range is ignored rather than producing a negative span")
end

do
	local comp = Layers.newComposition()
	local layers = { layerFor("a", 60, 0) }
	Harness.near(Layers.sanitizeMasterTime(0 / 0, comp, layers), 0, "NaN from an empty widget falls back to the window start")
	Harness.near(Layers.sanitizeMasterTime(999, comp, layers), 60, "an out-of-range scrub is clamped")
	Harness.near(Layers.sanitizeMasterTime(math.huge, comp, layers), 0, "infinity is rejected rather than poisoning the clock")
end

---- Progress and counts ------------------------------------------------------

do
	local layers = { layerFor("a", 20, 0), layerFor("b", 30, 0) }
	local comp = Layers.newComposition()
	comp.masterT = 10
	Harness.near(Layers.progress(comp, layers), 10 / 30, "progress is the clock over the longest layer")
	Harness.equal(Layers.usableCount(layers), 2, "usable count counts healthy layers")
	Harness.near(Layers.totalContentSeconds(layers), 50, "content seconds is the sum of durations")

	local empty = Layers.newComposition()
	Harness.near(Layers.progress(empty, {}), 0, "progress on an empty composition is 0, not NaN")
end

local failures = Harness.report()
if failures > 0 then
	error(string.format("%d replaylayers checks failed", failures), 0)
end
