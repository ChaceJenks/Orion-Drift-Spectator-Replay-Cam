--!strict
--[[
	PRE-PROBE - a throwaway camera script, run this BEFORE trusting the full
	replay camera.

	It answers the three questions that only the running client can answer, and
	prints the answers instead of assuming them:

	  1. Does the Replay API behave the way the docs say, in this build?
	     (listAll vs listLoaded shapes, getDurationSeconds, getStartTime().ticks,
	      whether setPlaybackTimeSeconds actually moves a replay, whether
	      isPlaying = false stops the client advancing it)
	  2. Do several loaded replays render as ordinary characters in the same world
	     at the same time? This is the single assumption the whole overlay rests
	     on, and it is not stated anywhere in the docs - only you can see it.
	  3. Does the free-fly control work at all from a Luau camera?

	Install: copy the whole probe/Behaviors folder into
	    %USERPROFILE%\Documents\Another-Axiom\A2\Cameras\Behaviors\
	F1 to show the GUI, F2 to pick "Pre-Probe", F3 for its panel, F4 for logs.

	Keys (they only work while this camera is the active one):
	  W A S D  move        Q / E   up / down
	  Right mouse button + mouse    look
	  1   load the first three replays listed by Replay.listAll()
	  2   align them by recorded start time
	  3   start / stop the master clock
	  4   dump the full report to the log
	  5   ride the built-in Free Cam instead (the escape hatch)
	  6   stop riding it and take the camera back

	This file deliberately has no dependencies and pcall-wraps every API call, so
	an unsupported call shows up as a line in the report rather than a dead camera.
]]

type Row = {
	name: string,
	handle: any,
	duration: number,
	startTicks: number,
	offset: number,
	lastError: string,
}

local report: { string } = {}
local rows: { Row } = {}
local masterT = 0
local playing = false
local riding = false
local syncErrors = 0

-- Position is tracked in plain numbers: the vector operators are fine at runtime
-- but keeping it scalar means nothing in this file can fail on a metamethod.
local pos = { x = 0, y = 0, z = 200 }
local yaw = 0
local pitch = 0

local function say(line: string)
	table.insert(report, line)
	print("[preprobe] " .. line)
end

local function probe(label: string, call: () -> any): any
	local ok, value = pcall(call)
	if not ok then
		say("MISSING " .. label .. ": " .. tostring(value))
		return nil
	end
	return value
end

function main()
	say("---- API surface ----")
	probe("Replay.listAll", function()
		return #Replay.listAll()
	end)
	probe("Replay.listLoaded", function()
		return #Replay.listLoaded()
	end)
	probe("Settings.getLuauReplayControlAllowed", function()
		return Settings.getLuauReplayControlAllowed()
	end)
	probe("LuauFile.listFiles", function()
		return #LuauFile.listFiles("shots")
	end)
	probe("Screenshot.takeScreenshot present", function()
		return Screenshot.takeScreenshot ~= nil
	end)
	probe("DateTime.getCurrentTime().ticks", function()
		return DateTime.getCurrentTime().ticks
	end)
	probe("gravity.upDirection", function()
		local up = gravity.upDirection
		return string.format("strength=%.3f up=(%.2f,%.2f,%.2f)", gravity.strength, up.x, up.y, up.z)
	end)
	say("---- end ----")
end

local function loadFirstThree()
	rows = {}
	local names = probe("Replay.listAll", function()
		return Replay.listAll()
	end)
	if names == nil then
		return
	end
	for index = 1, math.min(#names, 3) do
		local name = names[index]
		local handle = probe("Replay.load(" .. name .. ")", function()
			return Replay.load(name)
		end)
		if handle ~= nil then
			local duration = probe("getDurationSeconds", function()
				return handle:getDurationSeconds()
			end) or 0
			local startTicks = probe("getStartTime().ticks", function()
				return handle:getStartTime().ticks
			end) or 0
			table.insert(rows, {
				name = name,
				handle = handle,
				duration = duration,
				startTicks = startTicks,
				offset = 0,
				lastError = "",
			})
		end
	end
	say(string.format("loaded %d replays", #rows))
end

local function alignByStartTime()
	-- Anchor on the EARLIEST start, so every offset is <= 0 and the composition
	-- never has to represent a negative time. Anchoring on the latest works too,
	-- but then t=0 sits in the middle of the overlay and the offsets flip sign.
	local anchor = 0
	for _, row in rows do
		if row.startTicks > 0 and (anchor == 0 or row.startTicks < anchor) then
			anchor = row.startTicks
		end
	end
	if anchor == 0 then
		say("no start ticks available, cannot align")
		return
	end
	for _, row in rows do
		if row.startTicks > 0 then
			-- DateTime exposes only ticks, in 100 ns intervals.
			row.offset = (anchor - row.startTicks) / 1e7
		else
			row.offset = 0
		end
	end
	say(string.format("aligned by recorded start time, anchor %.3f s", anchor / 1e7))
end

local function syncAll()
	for _, row in rows do
		local local_ = masterT + row.offset
		local_ = math.max(0, math.min(row.duration, local_))
		local ok, err = pcall(function()
			-- The important line: without clearing this, the client advances the
			-- replay itself and the layers slide out of step with each other.
			row.handle.isPlaying = false
			row.handle:setPlaybackTimeSeconds(local_)
		end)
		if not ok then
			syncErrors += 1
			row.lastError = tostring(err)
		end
	end
end

local function dump()
	say("---- report ----")
	say(string.format("masterT=%.3f playing=%s syncErrors=%d", masterT, tostring(playing), syncErrors))
	local cameraPos = camera.position
	say(string.format("camera pos=(%.0f,%.0f,%.0f) fov=%.1f active=%s", cameraPos.x, cameraPos.y, cameraPos.z, camera.fieldOfView, tostring(camera.isActive)))
	for _, row in rows do
		local readBack = probe("getPlaybackTimeSeconds", function()
			return row.handle:getPlaybackTimeSeconds()
		end)
		say(string.format(
			"%s  dur=%.2fs  start=%.3f  offset=%+.3f  driven=%.3f  readBack=%s  err=%s",
			row.name,
			row.duration,
			row.startTicks / 1e7,
			row.offset,
			masterT + row.offset,
			tostring(readBack),
			if #row.lastError > 0 then row.lastError else "none"
		))
	end
	say(">>> LOOK AT THE SCREEN: are all of those replays visible as ordinary")
	say(">>> characters at once? Count the distinct players and check they move")
	say(">>> together as you scrub. That is the answer the docs never give.")
	say("---- end ----")
end

function tick(dt: number)
	if riding then
		return
	end
	if not camera.isActive then
		return
	end

	-- Look, only while the right mouse button is held, because there is no
	-- documented "does the GUI want the mouse" query to fall back on.
	if Input.getKey(Input.Key.RightMouseButton) then
		local delta = Input.getMouseDelta()
		yaw += delta.x * 0.15
		pitch -= delta.y * 0.15
		if pitch > 89 then
			pitch = 89
		elseif pitch < -89 then
			pitch = -89
		end
	end

	-- Movement, in the yaw/pitch basis. All scalar so no operator is needed.
	local speed = if Input.getKey(Input.Key.LeftShift) then 1800 else 600
	local forward = 0
	local strafe = 0
	local vertical = 0
	if Input.getKey(Input.Key.W) then
		forward += 1
	end
	if Input.getKey(Input.Key.S) then
		forward -= 1
	end
	if Input.getKey(Input.Key.D) then
		strafe += 1
	end
	if Input.getKey(Input.Key.A) then
		strafe -= 1
	end
	if Input.getKey(Input.Key.E) then
		vertical += 1
	end
	if Input.getKey(Input.Key.Q) then
		vertical -= 1
	end

	local yawRad = math.rad(yaw)
	local pitchRad = math.rad(pitch)
	local fx = math.cos(pitchRad) * math.cos(yawRad)
	local fy = math.cos(pitchRad) * math.sin(yawRad)
	local fz = math.sin(pitchRad)
	local rx = -math.sin(yawRad)
	local ry = math.cos(yawRad)

	local axisScale = if (forward ~= 0 and strafe ~= 0) then 0.7071 else 1
	pos.x += (fx * forward + rx * strafe) * speed * axisScale * dt
	pos.y += (fy * forward + ry * strafe) * speed * axisScale * dt
	pos.z += fz * vertical * speed * dt

	camera.position = Vec3.new(pos.x, pos.y, pos.z)
	camera:lookAt(
		Vec3.new(pos.x + fx * 100, pos.y + fy * 100, pos.z + fz * 100),
		Vec3.new(0, 0, 1)
	)
	camera.fieldOfView = 90

	-- Keys. getKeyDown is the "just pressed this frame" form.
	if Input.getKeyDown(Input.Key.One) then
		loadFirstThree()
	end
	if Input.getKeyDown(Input.Key.Two) then
		alignByStartTime()
	end
	if Input.getKeyDown(Input.Key.Three) then
		playing = not playing
		say("clock " .. if playing then "running" else "paused")
	end
	if Input.getKeyDown(Input.Key.Four) then
		dump()
	end
	if Input.getKeyDown(Input.Key.Five) then
		local freeCam = getCameraById("anotheraxiom.freecam")
		if freeCam ~= nil then
			camera:followCamera(freeCam)
			riding = true
			say("riding the built-in Free Cam; press 6 to take control back")
		else
			say("anotheraxiom.freecam not found")
		end
	end
	if Input.getKeyDown(Input.Key.Six) then
		camera:followCamera(nil)
		riding = false
		say("camera control returned")
	end

	if playing then
		masterT += dt
		local shortest = math.huge
		for _, row in rows do
			shortest = math.min(shortest, row.duration)
		end
		if shortest < math.huge and masterT > shortest then
			masterT = 0
		end
	end
	syncAll()
end

function onGui()
	Gui.text("Pre-Probe - keys 1..6, WASD/QE, RMB to look")
	Gui.text(string.format("masterT %.2f   playing %s   layers %d   syncErrors %d", masterT, tostring(playing), #rows, syncErrors))
	Gui.separator()
	for _, row in rows do
		Gui.text(string.format(
			"%s  dur %.1fs  offset %+.2fs  at %.2fs",
			row.name,
			row.duration,
			row.offset,
			masterT + row.offset
		))
	end
	Gui.separator()
	local start = math.max(1, #report - 11)
	for index = start, #report do
		Gui.text(report[index])
	end
end
