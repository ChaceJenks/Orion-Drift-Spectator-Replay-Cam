--!strict
--[[
	The replay overlay: several .a2replay files stacked in the same world space,
	driven from one authoritative master clock.

	Two rules make the overlay behave:

	1. **Single writer.** While syncMode is "masterClock" this module is the only
	   thing that moves playback time, and it forces `isPlaying = false` on every
	   handle. If the client were also advancing replays, each layer would drift
	   at its own frame-schedule rate and the overlay would slide out of step.

	2. **One coordinate, offsets as deltas.** The clock is `masterT`, measured in
	   seconds of the composition. A layer's own replay time is simply
	   `masterT + layer.offset`, so scrubbing, speed and pausing are all free for
	   every layer at once, and per-replay offsets stay meaningful.

	`offset` may be negative, which is exactly what wallclock alignment produces
	for a replay that started before the others, so masterT is not assumed to be
	non-negative anywhere in this file.
]]

local Types = require("types")
local Util = require("util")

type Layer = Types.Layer
type Composition = Types.Composition
type ReplayHandle = Types.ReplayHandle
type DateTimeStruct = Types.DateTimeStruct
type Notice = Types.Notice

local Layers = {}

local TICKS_PER_SECOND = 1e7

---- Construction ---------------------------------------------------------------

function Layers.newComposition(): Composition
	return {
		syncMode = "masterClock",
		alignMode = "relative",
		loopMode = "loop",
		playing = false,
		speed = 1,
		masterT = 0,
		rangeStart = 0,
		rangeEnd = 0,
	}
end

function Layers.newLayer(file: string, label: string, duration: number, startTicks: number): Layer
	return {
		file = Util.basename(file),
		label = if #label > 0 then label else Util.shortReplayName(file),
		offset = 0,
		overflow = "hold",
		duration = if duration > 0 then duration else 0,
		startTicks = startTicks,
		missing = false,
		handle = nil,
	}
end

---- Layer collection -----------------------------------------------------------

function Layers.findByFile(layers: { Layer }, file: string): Layer?
	local wanted = Util.basename(file)
	for _, layer in layers do
		if layer.file == wanted then
			return layer
		end
	end
	return nil
end

function Layers.indexOfFile(layers: { Layer }, file: string): number?
	local wanted = Util.basename(file)
	for index, layer in layers do
		if layer.file == wanted then
			return index
		end
	end
	return nil
end

function Layers.add(layers: { Layer }, layer: Layer): boolean
	if Layers.indexOfFile(layers, layer.file) ~= nil then
		return false
	end
	table.insert(layers, layer)
	return true
end

function Layers.remove(layers: { Layer }, file: string): boolean
	local index = Layers.indexOfFile(layers, file)
	if index == nil then
		return false
	end
	table.remove(layers, index)
	return true
end

-- True when a layer still has something to show, i.e. it is worth driving.
function Layers.isUsable(layer: Layer): boolean
	return layer.handle ~= nil and not layer.missing and layer.duration > 0
end

---- Handle reconciliation ------------------------------------------------------
-- Handles are not stable: the Replays panel (or another camera script) can
-- unload files at any time, and every unload renumbers Replay.getByIndex(). So
-- handles are re-resolved from a fresh snapshot instead of being cached, and a
-- layer whose file disappeared is marked missing rather than indexed blindly.

function Layers.reconcile(layers: { Layer }, handlesByFile: { [string]: ReplayHandle }): { Notice }
	local notices: { Notice } = {}
	for _, layer in layers do
		local handle = handlesByFile[layer.file]
		if handle ~= nil then
			if layer.missing then
				table.insert(notices, { kind = "info", text = "Recovered handle for " .. layer.label })
			end
			layer.handle = handle
			layer.missing = false
		elseif layer.handle ~= nil then
			layer.handle = nil
			layer.missing = true
			table.insert(notices, { kind = "warn", text = "Lost handle for " .. layer.label .. " (unloaded?)" })
		else
			layer.missing = true
		end
	end
	return notices
end

-- Refreshes the cached duration/timestamp of every layer that has a handle. The
-- cache exists so the timeline and the layer rows do not query the client every
-- frame, and so a lost handle cannot make the UI show a stale-but-live duration.
function Layers.refreshMetadata(layers: { Layer }): { Notice }
	local notices: { Notice } = {}
	for _, layer in layers do
		local handle = layer.handle
		if handle ~= nil then
			local duration, durationError = Util.try(function()
				return handle:getDurationSeconds()
			end)
			if durationError == nil and type(duration) == "number" and (duration :: number) > 0 then
				layer.duration = duration :: number
			end
			if layer.startTicks == 0 then
				local startTime, timeError = Util.try(function()
					return handle:getStartTime()
				end)
				if timeError == nil and startTime ~= nil and type((startTime :: DateTimeStruct).ticks) == "number" then
					layer.startTicks = (startTime :: DateTimeStruct).ticks
				end
			end
		end
	end
	return notices
end

---- Alignment ------------------------------------------------------------------

-- Earliest recorded start time across the layers, or 0 when no layer has one.
function Layers.anchorTicks(layers: { Layer }): number
	local anchor = 0
	for _, layer in layers do
		if layer.startTicks > 0 and (anchor == 0 or layer.startTicks < anchor) then
			anchor = layer.startTicks
		end
	end
	return anchor
end

--[[
	Aligns layers by when they were actually recorded, which is the right choice
	for several replays taken from the same server session: a player in replay B
	appears where they were at the same wall-clock instant as replay A.

	DateTime only exposes `ticks` (100 ns intervals), so the difference is scaled
	by 1e7.

	Working out the sign: if layer i covers wall seconds starting at start_i, and
	masterT is measured from an anchor A, then staying on the same wall instant
	needs `masterT + offset_i = (masterT + A) - start_i`, so `offset_i = A - start_i`.

	A is the *earliest* start, which makes every offset <= 0. That choice is
	deliberate: it means the composition window starts at t=0 instead of dipping
	negative, which keeps the timeline labels, the scrub range and any recorded
	camera-path keyframes all non-negative. The cost is that during the head, the
	layers that began later report a negative local time; "hold" resolves that to
	their first frame, which is the honest answer - that replay had not started
	recording yet.
]]
function Layers.alignToWallclock(layers: { Layer }): number
	local anchor = Layers.anchorTicks(layers)
	if anchor == 0 then
		return 0
	end
	for _, layer in layers do
		if layer.startTicks > 0 then
			layer.offset = Util.ticksToSeconds(anchor - layer.startTicks)
		else
			-- No timestamp available: keep it at the composition start.
			layer.offset = 0
		end
	end
	return anchor
end

function Layers.resetOffsets(layers: { Layer })
	for _, layer in layers do
		layer.offset = 0
	end
end

---- Window ---------------------------------------------------------------------

-- The span of masterT over which at least one layer has frames to show, using
-- the layer offsets. Returns (0, 0) for an empty composition so callers can use
-- the result without special-casing.
function Layers.naturalWindow(layers: { Layer }): (number, number)
	local start = 0
	local finish = 0
	local seen = false
	for _, layer in layers do
		local windowStart = -layer.offset
		local windowEnd = layer.duration - layer.offset
		if not seen then
			start, finish = windowStart, windowEnd
			seen = true
		else
			start = math.min(start, windowStart)
			finish = math.max(finish, windowEnd)
		end
	end
	if not seen then
		return 0, 0
	end
	if finish < start then
		return start, start
	end
	return start, finish
end

-- The window actually used for playback: the user's clip range when it is set,
-- otherwise the natural window. A range is only honoured when it has a positive
-- span, which is how "auto" is represented without a separate flag.
function Layers.effectiveWindow(comp: Composition, layers: { Layer }): (number, number)
	local start, finish = Layers.naturalWindow(layers)
	if comp.rangeEnd > comp.rangeStart then
		start = comp.rangeStart
		finish = comp.rangeEnd
		if finish < start then
			finish = start
		end
	end
	return start, finish
end

---- Clock ----------------------------------------------------------------------

-- Local replay time for one layer at a given master clock value.
-- Returns nil only when the layer cannot be driven at all.
function Layers.layerTime(layer: Layer, masterT: number): number?
	if layer.duration <= 0 then
		return nil
	end
	local local_ = masterT + layer.offset
	if local_ >= 0 and local_ <= layer.duration then
		return local_
	end
	if layer.overflow == "loop" then
		-- Lua's modulo already yields a non-negative result for a positive
		-- divisor, so this handles negative times without extra branching.
		return local_ % layer.duration
	end
	-- "hold": pin to whichever end the clock has passed.
	if local_ < 0 then
		return 0
	end
	return layer.duration
end

-- Advances the clock by dt seconds. Mutates comp. Returns a notice when the
-- clock stops itself, so the UI can show why playback halted.
function Layers.advance(comp: Composition, layers: { Layer }, dt: number): Notice?
	if not comp.playing or dt <= 0 then
		return nil
	end
	comp.masterT = comp.masterT + dt * comp.speed

	local start, finish = Layers.effectiveWindow(comp, layers)
	local span = finish - start
	if span <= 0 then
		comp.masterT = start
		comp.playing = false
		return { kind = "info", text = "Nothing to play - no loaded layer has a duration." }
	end

	if comp.masterT > finish then
		if comp.loopMode == "loop" then
			comp.masterT = start + ((comp.masterT - start) % span)
		elseif comp.loopMode == "stop" then
			comp.masterT = finish
			comp.playing = false
			return { kind = "info", text = "Reached the end of the composition." }
		else
			-- holdEnd: keep playing so a recorded camera path can finish, while
			-- the layers themselves sit on their last frame.
			comp.masterT = finish
		end
	elseif comp.masterT < start then
		if comp.loopMode == "loop" then
			comp.masterT = finish - ((start - comp.masterT) % span)
		else
			comp.masterT = start
			if comp.loopMode == "stop" then
				comp.playing = false
				return { kind = "info", text = "Reached the start of the composition." }
			end
		end
	end
	return nil
end

-- Pushes the clock to every layer. Returns one notice per layer that failed, so
-- a single bad handle cannot take the whole overlay down.
function Layers.syncToClock(comp: Composition, layers: { Layer }): { Notice }
	local notices: { Notice } = {}

	if comp.syncMode == "independent" then
		-- Hand control back to the client. This is the "load them and let them
		-- run" behaviour: simpler, but layers drift relative to each other and
		-- the master clock no longer describes what is on screen.
		for _, layer in layers do
			local handle = layer.handle
			if handle ~= nil then
				local _, err = Util.try(function()
					handle.isPlaying = comp.playing
					return true
				end)
				if err ~= nil then
					table.insert(notices, { kind = "error", text = layer.label .. ": " .. err })
				end
			end
		end
		return notices
	end

	for _, layer in layers do
		local handle = layer.handle
		if handle ~= nil then
			local time = Layers.layerTime(layer, comp.masterT)
			if time ~= nil then
				local _, err = Util.try(function()
					-- Clear the flag first: it is what stops the client advancing
					-- this replay underneath us.
					handle.isPlaying = false
					handle:setPlaybackTimeSeconds(time)
					return true
				end)
				if err ~= nil then
					table.insert(notices, { kind = "error", text = layer.label .. ": " .. err })
					layer.missing = true
					layer.handle = nil
				end
			end
		end
	end
	return notices
end

---- Queries for the UI ---------------------------------------------------------

-- Progress through the composition in 0..1, used for the progress bar and for
-- jumping to the next/previous layer boundary.
function Layers.progress(comp: Composition, layers: { Layer }): number
	local start, finish = Layers.effectiveWindow(comp, layers)
	local span = finish - start
	if span <= 0 then
		return 0
	end
	return Util.clamp((comp.masterT - start) / span, 0, 1)
end

function Layers.usableCount(layers: { Layer }): number
	local count = 0
	for _, layer in layers do
		if Layers.isUsable(layer) then
			count += 1
		end
	end
	return count
end

-- Total seconds of layer content, for the "loaded N replays (M s of content)"
-- status line.
function Layers.totalContentSeconds(layers: { Layer }): number
	local total = 0
	for _, layer in layers do
		total += layer.duration
	end
	return total
end

-- Sanity-checks a clock value coming from a widget (drag/slider input can produce
-- anything, including NaN from an empty text box).
function Layers.sanitizeMasterTime(value: number, comp: Composition, layers: { Layer }): number
	local start, finish = Layers.effectiveWindow(comp, layers)
	if not Util.isFiniteNumber(value) then
		return start
	end
	if finish > start then
		return Util.clamp(value, start, finish)
	end
	return start
end

-- For diagnostics in the Debug tab.
function Layers.describeTickRate(): number
	return TICKS_PER_SECOND
end

return Layers
