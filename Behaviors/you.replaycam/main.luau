--!strict
--[[
	Replay Cam - a free-fly spectator camera that records, and that can stack
	several replays in the world at once as ordinary characters.

	Layout of this file:

		main()            read config, build the shared model, report what the
						client actually gave us.
		tick(dt)          hotkeys -> master clock -> replay sync -> fly -> camera.
		onGui()           the panel (see ui.luau).
		onConfigChanged() re-read config without losing the session.

	Anything with maths in it lives in the sibling modules and is covered by the
	tests in dev/. This file is wiring only: reading input, calling into the client,
	and writing the camera. It is the only module that touches the engine globals,
	which is exactly what makes the rest of the package testable without the client
	running.

	Two rules the wiring keeps throughout:

	* One writer. Every loaded replay is driven from comp.masterT by
	  Layers.syncToClock, which forces isPlaying off and sets the time by hand. The
	  client's own playback would otherwise race with us and the stack would drift
	  apart - the whole overlay depends on this.
	* Nothing optional is assumed. Package files, screenshots, the timeline widget
	  and even the per-replay start timestamp are probed rather than trusted, so
	  the panel degrades with a clear message instead of erroring every frame.
]]

local Types = require("types")
local Util = require("util")
local VecMath = require("vecmath")
local Layers = require("replaylayers")
local Fly = require("flycamera")
local Path = require("camerapath")
local ShotFile = require("shotfile")
local ReplayRecorder = require("replayrecorder")
local Ui = require("ui")

type AppState = Types.AppState
type Layer = Types.Layer
type Notice = Types.Notice
type FlySettings = Types.FlySettings
type FlyIntent = Types.FlyIntent
type CameraPath = Types.CameraPath
type ReplayHandle = Types.ReplayHandle
type Vec3Struct = Types.Vec3Struct
type AxisRotate = Fly.AxisRotate
type SampledPose = Path.SampledPose
type RecorderApi = ReplayRecorder.RecorderApi
type ClipApi = ReplayRecorder.ClipApi

local FREECAM_ID = "anotheraxiom.freecam"
local SHOT_FOLDER = "shots"
local FRAME_SECONDS = 1 / 60
local NOTICES_KEPT = 40
local REFRESH_SECONDS = 2
local JSON_SUFFIX = ".json"

---- Configuration -------------------------------------------------------------

-- Flat keys, because that is what the client's per-camera JSON config is, so a
-- hand edit works. Every value is coerced and clamped on the way in.
local DEFAULTS = {
	moveSpeed = 900,
	boostMultiplier = 4,
	fineMultiplier = 0.15,
	inertia = true,
	dampingTime = 0.35,
	lookSensitivity = 0.12,
	freeLook = false,
	alignRoll = true,
	positionSmoothing = 0.12,
	rotationSmoothing = 0.12,
	fov = 90,
	followBuiltInFreecam = false,
	recordTargetSeconds = ReplayRecorder.defaultTargetSeconds,
	pathSampleHz = 30,
	pathMaxKeys = 20000,
	pathBlend = 0.5,
	layerCap = 8,
}

local settings: FlySettings = {
	moveSpeed = DEFAULTS.moveSpeed,
	boostMultiplier = DEFAULTS.boostMultiplier,
	fineMultiplier = DEFAULTS.fineMultiplier,
	inertia = DEFAULTS.inertia,
	dampingTime = DEFAULTS.dampingTime,
	lookSensitivity = DEFAULTS.lookSensitivity,
	freeLook = DEFAULTS.freeLook,
	alignRoll = DEFAULTS.alignRoll,
	positionSmoothing = DEFAULTS.positionSmoothing,
	rotationSmoothing = DEFAULTS.rotationSmoothing,
	fov = DEFAULTS.fov,
	followBuiltInFreecam = DEFAULTS.followBuiltInFreecam,
}

-- Settings that are not camera-movement maths, so not part of FlySettings.
local recordTargetSeconds = DEFAULTS.recordTargetSeconds
local pathMaxKeys = DEFAULTS.pathMaxKeys
local pathBlend = DEFAULTS.pathBlend
local layerCap = DEFAULTS.layerCap

---- Shared model --------------------------------------------------------------

local comp = Layers.newComposition()
local layers: { Layer } = {}
local record = ReplayRecorder.newState()
local fly = Fly.newState(0, 0, 200, 0, 0)
local pathRecorder = Path.newRecorder(DEFAULTS.pathSampleHz, DEFAULTS.pathMaxKeys)
local pathTimeOffset = 0

-- Everything else is session state, not model and not config.
local app: AppState? = nil
local buildAppState: () -> AppState -- assigned at the end; it points at the commands

local pathRecording = false
local ridingFreecam = false
local seeded = false
local wasActive = false
local refreshCountdown = 0
local framesPerSecond = 0
local syncErrors = 0
local errorCount = 0
local lastError = ""
local guardFailures = 0
local guardDisabled = false
local canControlReplays = true
local canWriteReplays = false
local canWriteFiles = false
local canScreenshot = false

-- Functions that are used before their definition, which is normal for a frame
-- loop. Forward declared as locals so nothing here leaks into the global
-- namespace the client shares with other cameras.
local writeConfig: () -> ()
local refresh: () -> ()
local handleHotkeys: () -> ()
local applyManualPose: () -> ()
local applyPathPose: (SampledPose, number) -> ()

---- Errors and notices --------------------------------------------------------

--[[
	Any error inside the frame loop is caught, summarised and rate limited. A camera
	that throws every frame would otherwise flood the Camera Logs panel (F4) and
	make the tool unusable, so identical messages are counted rather than repeated,
	and a failure that never resolves stops the loop instead of spinning forever.
]]
local function noteError(where: string, raw: any)
	errorCount += 1
	guardFailures += 1
	local text = string.format("%s: %s", where, Util.errorText(raw))
	if text ~= lastError then
		lastError = text
		warn("[replaycam] " .. text)
	end
	if guardFailures == 120 then
		guardDisabled = true
		warn("[replaycam] repeated errors with no success in between; this camera has stopped updating. Reload it to try again.")
	end
end

local function guard(where: string, body: () -> ...any)
	if guardDisabled then
		return
	end
	local ok, raw = pcall(body)
	if ok then
		guardFailures = 0
	else
		noteError(where, raw)
	end
end

-- Notices are deduplicated against the ones still on screen. syncToClock can emit
-- the same message every frame, and a panel of repeats says less than one line
-- that stays put.
local function pushNotice(notice: Notice)
	local state = app
	if state == nil then
		return
	end
	for _, existing in state.notices do
		if existing.text == notice.text then
			return
		end
	end
	table.insert(state.notices, 1, notice)
	while #state.notices > NOTICES_KEPT do
		table.remove(state.notices)
	end
end

local function pushAll(notices: { Notice })
	for _, notice in notices do
		pushNotice(notice)
	end
end

---- Client access, all of it defensive ---------------------------------------

local function nowTicks(): number
	local value, err = Util.try(function()
		return DateTime.getCurrentTime().ticks
	end)
	if err ~= nil or type(value) ~= "number" then
		return 0
	end
	return value :: number
end

-- Basenames only. listAll may report bare names while listLoaded reports full
-- paths, so the basename is the only key both agree on.
local function listFiles(): { string }
	local value, err = Util.try(function()
		return Replay.listAll()
	end)
	if err ~= nil or type(value) ~= "table" then
		return {}
	end
	local names: { string } = {}
	for _, entry in value :: { any } do
		if type(entry) == "string" then
			table.insert(names, Util.basename(entry :: string))
		end
	end
	return names
end

local function listLoaded(): { string }
	local value, err = Util.try(function()
		return Replay.listLoaded()
	end)
	if err ~= nil or type(value) ~= "table" then
		return {}
	end
	local names: { string } = {}
	for _, entry in value :: { any } do
		if type(entry) == "string" then
			table.insert(names, entry :: string)
		end
	end
	return names
end

-- Handles keyed by basename. getByIndex can return nil against a stale index
-- list, a known trap, so every index is checked rather than trusted.
local function loadedHandles(): { [string]: ReplayHandle }
	local map: { [string]: ReplayHandle } = {}
	local loaded = listLoaded()
	for index = 1, #loaded do
		local handle, err = Util.try(function()
			return Replay.getByIndex(index)
		end)
		if err == nil and handle ~= nil then
			map[Util.basename(loaded[index])] = handle :: any
		end
	end
	return map
end

--[[
	Loads a replay by name, trying the spellings the client has been seen to
	accept. listAll gives bare names, load() wants a name inside the replays folder,
	and a name restored from a shot file may carry a directory or an extension.
	Rather than guess one, try the plausible forms in order.
]]
local function loadReplay(name: string): ReplayHandle?
	local short = Util.shortReplayName(name)
	local seen: { [string]: boolean } = {}
	for _, candidate in { name, short, short .. JSON_SUFFIX } do
		if #candidate > 0 and not seen[candidate] then
			seen[candidate] = true
			local handle, err = Util.try(function()
				return Replay.load(candidate)
			end)
			if err == nil and handle ~= nil then
				return handle :: any
			end
		end
	end
	return nil
end

local function booleanCall(callable: () -> any): boolean
	local value, err = Util.try(callable)
	return err == nil and value == true
end

local function recorderApi(): RecorderApi
	return {
		listAll = listFiles,
		startRecording = function(): boolean
			return booleanCall(function()
				return Replay.startRecording()
			end)
		end,
		stopRecording = function(): boolean
			return booleanCall(function()
				return Replay.stopRecording()
			end)
		end,
		nowTicks = nowTicks,
	}
end

local function clipApi(): ClipApi
	return {
		load = function(fileName: string): ReplayRecorder.ClipHandle?
			return loadReplay(fileName) :: any
		end,
	}
end

--[[
	Which optional APIs this build really offers, so the panel can state it up
	front instead of failing on a button press. Clip export additionally needs
	saveSegmentToFile on the replay object, which older builds do not have, so it
	is probed on a real handle rather than assumed.
]]
local function probeCapabilities()
	local control, controlError = Util.try(function()
		return Settings.getLuauReplayControlAllowed()
	end)
	canControlReplays = if controlError == nil and type(control) == "boolean" then control :: boolean else true

	local files, filesError = Util.try(function()
		return type(LuauFile) == "table"
	end)
	canWriteFiles = filesError == nil and files == true

	local shot, shotError = Util.try(function()
		return type(Screenshot) == "table" and type(Screenshot.takeScreenshot) == "function"
	end)
	canScreenshot = shotError == nil and shot == true

	canWriteReplays = false
	if canControlReplays then
		local _, handle = next(loadedHandles())
		if handle ~= nil then
			local hasSegment, segmentError = Util.try(function()
				return (handle :: any).saveSegmentToFile ~= nil
			end)
			canWriteReplays = segmentError == nil and hasSegment == true
		end
	end
end

---- Pose maths that needs the engine ------------------------------------------

-- Local-up basis. Where the client reports no gravity - the zero-g arenas - or
-- the gravity component is missing, this falls back to the plain world axes.
local function gravityRotate(x: number, y: number, z: number): Vec3Struct
	local rotated, err = Util.try(function()
		local up = gravity.upRotation
		if up == nil then
			return nil
		end
		return up:rotateVector(Vec3.new(x, y, z))
	end)
	if err ~= nil or rotated == nil then
		return { x = x, y = y, z = z }
	end
	return rotated :: Vec3Struct
end

-- Reads the pose the client is really showing. A captured path has to store this,
-- not the value we asked for: recording the request would bake in the smoothing
-- lag and the re-run would trail the original.
local function readPose(): (number, number, number, number, number, number, number, number)
	local position, positionError = Util.try(function()
		return camera:getSmoothedPosition()
	end)
	local rotation, rotationError = Util.try(function()
		return camera:getSmoothedRotation()
	end)
	local view, viewError = Util.try(function()
		return camera:getSmoothedFieldOfView()
	end)
	local point = if positionError == nil then position :: any else nil
	local turning = if rotationError == nil then rotation :: any else nil
	return if point ~= nil then point.x :: number else fly.x,
		if point ~= nil then point.y :: number else fly.y,
		if point ~= nil then point.z :: number else fly.z,
		if turning ~= nil then turning.x :: number else 0,
		if turning ~= nil then turning.y :: number else 0,
		if turning ~= nil then turning.z :: number else 0,
		if turning ~= nil then turning.w :: number else 1,
		if viewError == nil and type(view) == "number" then view :: number else settings.fov
end

--[[
	Yaw from a forward vector, in degrees, measured from +X towards +Y. Written out
	because the two-argument form of math.atan is not available in this
	environment, and getting the quadrant wrong would flip the camera 180 degrees
	on the first frame after selecting it.
]]
local function yawFromForward(x: number, y: number): number
	if x == 0 and y == 0 then
		return fly.yaw
	end
	local angle = math.atan(if x ~= 0 then y / x else if y >= 0 then math.huge else -math.huge)
	if x < 0 then
		angle += if y >= 0 then math.pi else -math.pi
	end
	return math.deg(angle)
end

-- Adopts the camera's current pose, so selecting this camera never teleports the
-- view away from wherever the last camera left it.
local function seedFromCamera()
	local position, positionError = Util.try(function()
		return camera:getSmoothedPosition()
	end)
	if positionError == nil and position ~= nil then
		local point = position :: any
		fly.x = point.x :: number
		fly.y = point.y :: number
		fly.z = point.z :: number
	end
	local rotation, rotationError = Util.try(function()
		return camera:getSmoothedRotation()
	end)
	if rotationError == nil and rotation ~= nil then
		local forward = (rotation :: any):getForwardVector() :: Vec3Struct
		fly.yaw = yawFromForward(forward.x, forward.y)
		fly.pitch = VecMath.clampPitch(math.deg(math.asin(Util.clamp(forward.z, -1, 1))))
	end
	Fly.stopMotion(fly)
	seeded = true
end

---- Input --------------------------------------------------------------------

local function axis(negative: any, positive: any): number
	local back = booleanCall(function()
		return Input.getKey(negative)
	end)
	local forward = booleanCall(function()
		return Input.getKey(positive)
	end)
	return (if forward then 1 else 0) - (if back then 1 else 0)
end

local function keyPressed(key: any): boolean
	return booleanCall(function()
		return Input.getKeyDown(key)
	end)
end

local function readIntent(): FlyIntent
	local delta, deltaError = Util.try(function()
		return Input.getMouseDelta()
	end)
	local rawX = if deltaError == nil and delta ~= nil then (delta :: any).x :: number else 0
	-- Delta Y grows downwards while pitch is up-positive, so it is negated here:
	-- pulling the mouse up looks up.
	local rawY = if deltaError == nil and delta ~= nil then -((delta :: any).y :: number) else 0

	-- The API cannot say whether the panel wants the mouse, so look is gated on the
	-- right mouse button unless the user opted out of that safety.
	local lookAllowed = settings.freeLook
		or booleanCall(function()
			return Input.getKey(Input.Key.RightMouseButton)
		end)

	local boost = 0
	if booleanCall(function()
		return Input.getKey(Input.Key.LeftShift)
	end) then
		boost = 1
	elseif booleanCall(function()
		return Input.getKey(Input.Key.LeftControl)
	end) then
		boost = -1
	end

	return {
		forward = axis(Input.Key.S, Input.Key.W),
		strafe = axis(Input.Key.A, Input.Key.D),
		vertical = axis(Input.Key.Q, Input.Key.E),
		lookX = if lookAllowed then rawX else 0,
		lookY = if lookAllowed then rawY else 0,
		roll = 0,
		boost = boost,
	}
end

---- Commands: the side-effecting half of the UI contract ---------------------

local function refreshBrowser(state: AppState)
	state.files = listFiles()
	state.loadedFiles = listLoaded()
	probeCapabilities()
	state.canControlReplays = canControlReplays
	state.canWriteReplays = canWriteReplays
	state.canWriteFiles = canWriteFiles
	state.canScreenshot = canScreenshot
	if canWriteFiles then
		local listing, err = Util.try(function()
			return LuauFile.listFiles(SHOT_FOLDER)
		end)
		if err == nil and type(listing) == "table" then
			state.shotFiles = listing :: { string }
		end
	end
end

refresh = function()
	local state = app
	if state == nil then
		return
	end
	refreshBrowser(state)
	pushAll(Layers.reconcile(layers, loadedHandles()))
	pushAll(Layers.refreshMetadata(layers))
end

local function doRefresh()
	refresh()
	local start, finish = Layers.naturalWindow(layers)
	if finish > start then
		comp.rangeStart = start
		comp.rangeEnd = finish
	end
end

local function handleFromLayer(name: string): (ReplayHandle?, number, number)
	local handle = loadReplay(name)
	if handle == nil then
		return nil, 0, 0
	end
	local duration, durationError = Util.try(function()
		return handle.getDurationSeconds(handle)
	end)
	local startTime, startError = Util.try(function()
		return handle.getStartTime(handle)
	end)
	local ticks = if startError == nil and startTime ~= nil then (startTime :: any).ticks :: number else 0
	return handle, if durationError == nil and type(duration) == "number" then duration :: number else 0, ticks
end

local function doAddLayer(file: string)
	local name = Util.basename(file)
	if Layers.findByFile(layers, name) ~= nil then
		pushNotice({ kind = "info", text = name .. " is already stacked." })
		return
	end
	if #layers >= layerCap then
		pushNotice({
			kind = "warn",
			text = string.format("Layer cap of %d reached. Remove one, or raise layerCap.", layerCap),
		})
		return
	end
	local handle, duration, startTicks = handleFromLayer(name)
	if handle == nil then
		pushNotice({ kind = "error", text = "The client would not load " .. name .. "." })
		return
	end
	local layer = Layers.newLayer(name, name, duration, startTicks)
	layer.handle = handle
	if not Layers.add(layers, layer) then
		return
	end
	pushNotice({ kind = "info", text = string.format("Stacked %s (%s).", name, Util.formatTime(duration)) })
	if comp.alignMode == "wallclock" and startTicks > 0 then
		Layers.alignToWallclock(layers)
	end
end

-- Deliberately does not unload. The client keeps the replay loaded, which is what
-- you want while building a shot, and unloading by index while other layers still
-- reference the same file is how handles get mis-attributed.
local function doRemoveLayer(file: string)
	if Layers.remove(layers, file) then
		pushNotice({
			kind = "info",
			text = Util.basename(file) .. " is off the overlay. It stays loaded in the client.",
		})
	end
end

local function doToggleRecording()
	local api = recorderApi()
	if ReplayRecorder.isRecording(record) then
		pushAll(ReplayRecorder.finish(record, api))
	else
		pushAll(ReplayRecorder.begin(record, api, recordTargetSeconds))
	end
	refresh()
end

local function doExportClip()
	local state = app
	if state == nil then
		return
	end
	local source = record.currentFile
	if #source == 0 and #layers > 0 then
		source = layers[1].file
	end
	if #source == 0 then
		pushNotice({ kind = "warn", text = "Nothing to clip. Stack or record a replay first." })
		return
	end
	local name = if #state.clipName > 0 then state.clipName else "clip"
	local ok, notices = ReplayRecorder.exportClip(clipApi(), source, name, state.clipStart, state.clipEnd)
	pushAll(notices)
	if ok then
		refreshBrowser(state)
	end
end

local function doTogglePathRecord()
	local state = app
	if pathRecording then
		pathRecording = false
		pushNotice({
			kind = "info",
			text = string.format("Captured %d keys over %s.", #pathRecorder.keys, Util.formatTime(Path.duration(pathRecorder))),
		})
		if state ~= nil and #pathRecorder.keys > 1 and state.cameraMode == "manual" then
			state.cameraMode = "followPath"
			pushNotice({ kind = "info", text = "Camera source switched to followPath. Press K to cycle it." })
		end
		return
	end
	if #pathRecorder.keys > 0 then
		pushNotice({ kind = "info", text = "Fresh capture; the old keyframes are replaced." })
	end
	Path.reset(pathRecorder)
	pathRecording = true
end

local function doToggleFreecam()
	if ridingFreecam then
		Util.try(function()
			camera:followCamera(nil)
			return nil
		end)
		ridingFreecam = false
		seeded = false
		pushNotice({ kind = "info", text = "Control returned to Replay Cam." })
		return
	end
	local target, err = Util.try(function()
		return getCameraById(FREECAM_ID)
	end)
	if err ~= nil or target == nil then
		pushNotice({ kind = "warn", text = "The built-in Free Cam (" .. FREECAM_ID .. ") is not available here." })
		return
	end
	local followed, followError = Util.try(function()
		camera:followCamera(target)
		return nil
	end)
	if followed ~= nil or followError == nil then
		ridingFreecam = true
		pushNotice({ kind = "info", text = "Riding the built-in Free Cam; its own keys fly the camera." })
	else
		pushNotice({ kind = "error", text = "Could not follow the Free Cam: " .. tostring(followError) })
	end
end

local function doScreenshot()
	if not canScreenshot then
		pushNotice({ kind = "warn", text = "Screenshots are not available in this build." })
		return
	end
	local path, err = Util.try(function()
		return Screenshot.takeScreenshot(0, 0)
	end)
	if err ~= nil or type(path) ~= "string" or #(path :: string) == 0 then
		pushNotice({ kind = "error", text = "The client refused the screenshot." })
	else
		pushNotice({ kind = "info", text = "Saved " .. (path :: string) })
	end
end

local function jsonApi(): ShotFile.JsonApi
	return {
		serialize = function(value: any, pretty: boolean): string
			return LuauJson.serialize(value, pretty)
		end,
		parse = function(text: string): any
			return LuauJson.parse(text)
		end,
	}
end

local function doSaveShot(name: string)
	if not canWriteFiles then
		pushNotice({ kind = "warn", text = "This build does not expose package files, so shots cannot be stored." })
		return
	end
	if #layers == 0 then
		pushNotice({ kind = "warn", text = "Nothing to save. Stack at least one replay first." })
		return
	end
	local pathForShot: CameraPath? = nil
	if #pathRecorder.keys > 0 then
		pathForShot = { sampleHz = pathRecorder.sampleHz, keys = pathRecorder.keys, offset = pathTimeOffset }
	end
	local shot = ShotFile.capture(if #name > 0 then name else "shot", comp, layers, pathForShot)
	local encoded, text = pcall(function()
		return ShotFile.encode(shot, jsonApi())
	end)
	if not encoded then
		pushNotice({ kind = "error", text = "Could not encode the shot: " .. Util.errorText(text) })
		return
	end
	local saved, saveError = Util.try(function()
		return LuauFile.saveText(ShotFile.shotPath(shot.name), text :: string)
	end)
	if saveError ~= nil or saved ~= true then
		pushNotice({ kind = "error", text = "Could not write " .. ShotFile.shotPath(shot.name) .. "." })
		return
	end
	pushNotice({
		kind = "info",
		text = string.format("Saved %s with %d layer(s).", ShotFile.shotPath(shot.name), #layers),
	})
	local state = app
	if state ~= nil then
		state.shotName = shot.name
		refreshBrowser(state)
	end
end

-- Replaces the overlay contents in place, so the panel keeps pointing at the same
-- array it has always pointed at.
local function restoreLayers(shot: Types.Shot)
	table.clear(layers)
	for _, layer in ShotFile.buildLayers(shot) do
		local handle, duration, startTicks = handleFromLayer(layer.file)
		layer.handle = handle
		layer.duration = duration
		layer.startTicks = startTicks
		layer.missing = handle == nil
		table.insert(layers, layer)
	end
end

local function shotPathFor(name: string): string
	if #name >= #JSON_SUFFIX and string.sub(name, -#JSON_SUFFIX) == JSON_SUFFIX then
		return SHOT_FOLDER .. "/" .. name
	end
	return ShotFile.shotPath(name)
end

local function doLoadShot(name: string)
	if not canWriteFiles then
		pushNotice({ kind = "warn", text = "This build does not expose package files, so shots cannot be read." })
		return
	end
	local path = shotPathFor(name)
	-- loadText returns (content, ok); pcall keeps both values, Util.try would drop
	-- the second.
	local callable, content, okFlag = pcall(function()
		return LuauFile.loadText(path)
	end)
	if not callable or not okFlag or type(content) ~= "string" then
		pushNotice({ kind = "error", text = "Could not read " .. path .. "." })
		return
	end
	local shot, problem = ShotFile.decode(content :: string, jsonApi())
	if shot == nil then
		pushNotice({ kind = "error", text = "That shot could not be read: " .. (problem or "unknown reason") })
		return
	end

	ShotFile.applyComposition(shot, comp)
	restoreLayers(shot)
	if shot.path ~= nil then
		local restored = shot.path :: CameraPath
		Path.reset(pathRecorder)
		pathRecorder.sampleHz = math.max(1, restored.sampleHz)
		pathRecorder.interval = 1 / pathRecorder.sampleHz
		pathRecorder.maxKeys = math.max(#restored.keys, 2)
		pathRecorder.keys = restored.keys
		pathTimeOffset = restored.offset
	end

	local missing = 0
	for _, layer in layers do
		if layer.missing then
			missing += 1
		end
	end
	pushNotice({
		kind = if missing == 0 then "info" else "warn",
		text = string.format(
			"Loaded shot '%s': %d layer(s)%s.",
			shot.name,
			#layers,
			if missing > 0 then ", " .. missing .. " replay file(s) missing" else ""
		),
	})
	local state = app
	if state ~= nil then
		state.shotName = shot.name
		state.pathOffset = pathTimeOffset
		state.pathKeys = pathRecorder.keys
	end
end

---- Model <-> view ------------------------------------------------------------

-- Pushes outputs into the panel's model. Runs every frame; it only copies numbers
-- and references.
local function syncView()
	local state = app
	if state == nil then
		return
	end
	state.pathKeys = pathRecorder.keys
	state.pathRecording = pathRecording
	state.pathTruncated = pathRecorder.truncated
	state.pathOffset = pathTimeOffset
	state.flySpeed = Fly.speed(fly)
	state.framesPerSecond = framesPerSecond
	state.syncErrors = syncErrors
	state.errorCount = errorCount
	state.lastError = lastError
	state.ridingFreecam = ridingFreecam
	state.canControlReplays = canControlReplays
	state.canWriteReplays = canWriteReplays
	state.canWriteFiles = canWriteFiles
	state.canScreenshot = canScreenshot
	state.pathMaxKeys = pathMaxKeys
	state.layerCap = layerCap
end

-- Pulls UI-edited numbers back into module state and persists a settings change.
local function readView()
	local state = app
	if state == nil then
		return
	end
	recordTargetSeconds = state.recordTargetSeconds
	pathBlend = state.pathBlend
	pathTimeOffset = state.pathOffset
	if state.pathSampleHz > 0 and state.pathSampleHz ~= pathRecorder.sampleHz then
		pathRecorder.sampleHz = state.pathSampleHz
		pathRecorder.interval = 1 / state.pathSampleHz
	end
	if state.settingsDirty then
		state.settingsDirty = false
		writeConfig()
	end
end

---- Config -------------------------------------------------------------------

writeConfig = function()
	-- The config global is the config file's customData block. A file that has no
	-- such block gives the script nothing to write into, and indexing it would throw
	-- inside the tick guard; keeping the built-in defaults is the honest outcome.
	if type(config) ~= "table" then
		return
	end
	config.moveSpeed = settings.moveSpeed
	config.boostMultiplier = settings.boostMultiplier
	config.fineMultiplier = settings.fineMultiplier
	config.inertia = settings.inertia
	config.dampingTime = settings.dampingTime
	config.lookSensitivity = settings.lookSensitivity
	config.freeLook = settings.freeLook
	config.alignRoll = settings.alignRoll
	config.positionSmoothing = settings.positionSmoothing
	config.rotationSmoothing = settings.rotationSmoothing
	config.fov = settings.fov
	config.followBuiltInFreecam = settings.followBuiltInFreecam
	config.recordTargetSeconds = recordTargetSeconds
	config.pathSampleHz = pathRecorder.sampleHz
	config.pathMaxKeys = pathMaxKeys
	config.pathBlend = pathBlend
	config.layerCap = layerCap
	Util.try(function()
		return saveConfig()
	end)
end

local function readConfig()
	if type(config) ~= "table" then
		-- Nothing to read: a fresh install whose config file has no customData block
		-- yet. The values already in `settings` are the built-in defaults, so the
		-- camera is fully usable and says so once instead of failing.
		log("[replaycam] the config file has no customData block; using built-in defaults")
		return
	end
	Util.applyDefaults(config, DEFAULTS)
	settings.moveSpeed = Util.num(config.moveSpeed, DEFAULTS.moveSpeed, 1, 1e6)
	settings.boostMultiplier = Util.num(config.boostMultiplier, DEFAULTS.boostMultiplier, 1, 100)
	settings.fineMultiplier = Util.num(config.fineMultiplier, DEFAULTS.fineMultiplier, 0.001, 1)
	settings.inertia = Util.bool(config.inertia, DEFAULTS.inertia)
	settings.dampingTime = Util.num(config.dampingTime, DEFAULTS.dampingTime, 0.01, 5)
	settings.lookSensitivity = Util.num(config.lookSensitivity, DEFAULTS.lookSensitivity, 0.001, 10)
	settings.freeLook = Util.bool(config.freeLook, DEFAULTS.freeLook)
	settings.alignRoll = Util.bool(config.alignRoll, DEFAULTS.alignRoll)
	settings.positionSmoothing = Util.num(config.positionSmoothing, DEFAULTS.positionSmoothing, 0, 5)
	settings.rotationSmoothing = Util.num(config.rotationSmoothing, DEFAULTS.rotationSmoothing, 0, 5)
	settings.fov = Util.num(config.fov, DEFAULTS.fov, 5, 170)
	settings.followBuiltInFreecam = Util.bool(config.followBuiltInFreecam, DEFAULTS.followBuiltInFreecam)
	recordTargetSeconds = Util.num(config.recordTargetSeconds, DEFAULTS.recordTargetSeconds, 0, 3600)
	pathMaxKeys = Util.int(config.pathMaxKeys, DEFAULTS.pathMaxKeys, 10, ShotFile.MAX_PATH_KEYS)
	pathBlend = Util.num(config.pathBlend, DEFAULTS.pathBlend, 0, 1)
	layerCap = Util.int(config.layerCap, DEFAULTS.layerCap, 1, 32)

	local sampleHz = Util.num(config.pathSampleHz, DEFAULTS.pathSampleHz, 1, 240)
	pathRecorder.sampleHz = sampleHz
	pathRecorder.interval = 1 / sampleHz
	pathRecorder.maxKeys = pathMaxKeys

	local state = app
	if state ~= nil then
		state.recordTargetSeconds = recordTargetSeconds
		state.pathMaxKeys = pathMaxKeys
		state.pathBlend = pathBlend
		state.layerCap = layerCap
		state.pathSampleHz = sampleHz
	end
end

---- Camera writes -------------------------------------------------------------

--[[
	Manual pose. Position is assigned directly; orientation goes through lookAt
	because it is the one orientation call the docs describe in terms of a target
	and an up vector. Assigning a hand-built quaternion would depend on the client's
	euler order, which is not documented.
]]
applyManualPose = function()
	if ridingFreecam then
		return
	end
	local rotate: AxisRotate = if settings.alignRoll then gravityRotate else nil
	local target, up = Fly.lookTarget(fly, rotate)
	Util.try(function()
		camera.position = Vec3.new(fly.x, fly.y, fly.z)
		camera:lookAt(Vec3.new(target.x, target.y, target.z), Vec3.new(up.x, up.y, up.z))
		camera.fieldOfView = settings.fov
		return nil
	end)
end

-- Path pose. blend 1 is the path alone; between 0 and 1 it is mixed with the
-- manual pose that applyManualPose just wrote, so the hand-over reads as one move
-- rather than a cut.
applyPathPose = function(pose: SampledPose, blend: number)
	local mixed = Util.clamp(blend, 0, 1)
	if mixed >= 1 then
		Util.try(function()
			camera.position = Vec3.new(pose.x, pose.y, pose.z)
			camera.rotation = Quat.new(pose.rx, pose.ry, pose.rz, pose.rw)
			camera.fieldOfView = pose.fov
			return nil
		end)
		return
	end

	Util.try(function()
		camera.position = Vec3.new(
			Util.lerp(fly.x, pose.x, mixed),
			Util.lerp(fly.y, pose.y, mixed),
			Util.lerp(fly.z, pose.z, mixed)
		)
		camera.fieldOfView = Util.lerp(settings.fov, pose.fov, mixed)
		return nil
	end)

	-- The manual orientation is read back rather than computed, which keeps this
	-- independent of how the client turns yaw and pitch into a quaternion.
	local current, err = Util.try(function()
		return camera.rotation
	end)
	if err ~= nil or current == nil then
		Util.try(function()
			camera.rotation = Quat.new(pose.rx, pose.ry, pose.rz, pose.rw)
			return nil
		end)
		return
	end
	local from = current :: any
	local rx, ry, rz, rw = VecMath.slerpQuat(
		from.x :: number,
		from.y :: number,
		from.z :: number,
		from.w :: number,
		pose.rx,
		pose.ry,
		pose.rz,
		pose.rw,
		mixed
	)
	Util.try(function()
		camera.rotation = Quat.new(rx, ry, rz, rw)
		return nil
	end)
end

---- Hotkeys ------------------------------------------------------------------
-- Read with getKeyDown so a press fires once, and only while this camera is the
-- active one. The spectator app itself owns F1 to F4.

handleHotkeys = function()
	local state = app
	if keyPressed(Input.Key.SpaceBar) then
		comp.playing = not comp.playing
	end
	if keyPressed(Input.Key.Home) then
		comp.playing = false
		comp.masterT = Layers.sanitizeMasterTime(0, comp, layers)
	end
	if keyPressed(Input.Key.Comma) then
		comp.playing = false
		comp.masterT = Layers.sanitizeMasterTime(comp.masterT - FRAME_SECONDS, comp, layers)
	end
	if keyPressed(Input.Key.Period) then
		comp.playing = false
		comp.masterT = Layers.sanitizeMasterTime(comp.masterT + FRAME_SECONDS, comp, layers)
	end
	if keyPressed(Input.Key.BackSpace) then
		Fly.stopMotion(fly)
	end
	if keyPressed(Input.Key.R) then
		doToggleRecording()
	end
	if keyPressed(Input.Key.C) then
		doExportClip()
	end
	if keyPressed(Input.Key.P) then
		doTogglePathRecord()
	end
	if keyPressed(Input.Key.K) and state ~= nil then
		state.cameraMode = if state.cameraMode == "manual"
			then "followPath"
			else if state.cameraMode == "followPath" then "blend" else "manual"
		pushNotice({ kind = "info", text = "Camera source: " .. state.cameraMode })
	end
	if keyPressed(Input.Key.F) then
		doToggleFreecam()
	end
	if keyPressed(Input.Key.V) then
		doScreenshot()
	end
end

---- Lifecycle ----------------------------------------------------------------

function main()
	guard("main", function()
		readConfig()
		probeCapabilities()
		-- The client only ticks an active camera by default, which is what keeps the
		-- master clock still while another camera has focus. alwaysTick is left alone.
		comp.syncMode = "masterClock"
		comp.alignMode = "relative"
		Util.try(function()
			camera.positionSmoothing = settings.positionSmoothing
			camera.rotationSmoothing = settings.rotationSmoothing
			camera.fieldOfViewSmoothing = 0
			return nil
		end)
		if app == nil then
			app = buildAppState()
		end
		refresh()
		if settings.followBuiltInFreecam then
			doToggleFreecam()
		end
		writeConfig()
		log(string.format(
			"[replaycam] ready: %d replay file(s) visible, replay control %s, package files %s, screenshots %s.",
			#listFiles(),
			if canControlReplays then "allowed" else "denied in spectator options",
			if canWriteFiles then "available" else "unavailable",
			if canScreenshot then "available" else "unavailable"
		))
	end)
end

function onConfigChanged()
	guard("onConfigChanged", function()
		readConfig()
	end)
end

function tick(dt: number)
	guard("tick", function()
		if not (dt > 0) then
			return
		end
		-- A huge dt means the client was paused or the editor hitched. Advancing the
		-- master clock by it would jump the whole overlay, so it is capped.
		local step = if dt > 1 then 1 / 15 else dt
		framesPerSecond = if framesPerSecond == 0 then 1 / step else framesPerSecond * 0.9 + (1 / step) * 0.1

		if not camera.isActive then
			wasActive = false
			return
		end
		if not wasActive then
			wasActive = true
			seeded = false
		end
		if not seeded and not ridingFreecam then
			seedFromCamera()
		end

		readView()
		handleHotkeys()

		-- 1. The master clock moves, then every loaded replay is told where that
		--    puts it. One writer, so the stack cannot drift.
		local advanceNotice = Layers.advance(comp, layers, step)
		if advanceNotice ~= nil then
			pushNotice(advanceNotice)
		end
		local syncNotices = Layers.syncToClock(comp, layers)
		syncErrors += #syncNotices
		pushAll(syncNotices)

		-- 2. The client's own recorder, including the auto-stop at the configured
		--    length (one minute by default).
		local recordNotice = ReplayRecorder.tick(record, recorderApi())
		if recordNotice ~= nil then
			pushNotice(recordNotice)
		end
		if ReplayRecorder.shouldAutoStop(record) then
			pushAll(ReplayRecorder.finish(record, recorderApi()))
			refresh()
		end

		-- 2b. The view has to keep up with the smoothing settings, which the panel may
		--     have just changed.
		Util.try(function()
			camera.positionSmoothing = settings.positionSmoothing
			camera.rotationSmoothing = settings.rotationSmoothing
			return nil
		end)

		-- 3. Where the camera should be this frame.
		if not ridingFreecam then
			local rotate: AxisRotate = if settings.alignRoll then gravityRotate else nil
			Fly.step(fly, readIntent(), settings, step, rotate)
		end

		local mode = if app ~= nil then app.cameraMode else "manual"
		local pose: SampledPose? = nil
		if mode ~= "manual" and #pathRecorder.keys > 0 then
			local path: CameraPath = {
				sampleHz = pathRecorder.sampleHz,
				keys = pathRecorder.keys,
				offset = pathTimeOffset,
			}
			pose = Path.sampleAt(path, comp.masterT)
		end

		if not ridingFreecam then
			applyManualPose()
			if pose ~= nil then
				applyPathPose(pose, if mode == "followPath" then 1 else pathBlend)
			end
		end

		-- 4. Capture from what the client is actually showing, so a re-run lands where
		--    the shot looked rather than where the maths said.
		if pathRecording then
			local px, py, pz, rx, ry, rz, rw, fov = readPose()
			Path.maybeRecord(pathRecorder, comp.masterT, px, py, pz, rx, ry, rz, rw, fov)
		end

		-- 5. Re-resolve handles periodically, so a replay loaded from the client's own
		--    UI shows up without a manual refresh.
		refreshCountdown -= step
		if refreshCountdown <= 0 then
			refreshCountdown = REFRESH_SECONDS
			pushAll(Layers.reconcile(layers, loadedHandles()))
			pushAll(Layers.refreshMetadata(layers))
		end

		syncView()
	end)
end

function onGui()
	guard("onGui", function()
		if app == nil then
			app = buildAppState()
		end
		if guardDisabled then
			-- The fallback has to be drawable without any of the model, because the
			-- model is what may have failed.
			Gui.text("Replay Cam stopped after repeated errors. Reload the camera to try again.")
			Gui.text("last error: " .. lastError)
			return
		end
		local state = app
		if state == nil then
			return
		end
		Ui.draw(state)
	end)
end

--[[
	Built once, then reused for the session: widgets write into this table, so it
	cannot be rebuilt per frame. It is assembled here, after the command functions
	exist, and assigned to the forward declaration near the top.
]]
buildAppState = function(): AppState
	local state: AppState = {
		comp = comp,
		layers = layers,
		record = record,
		fly = fly,
		settings = settings,
		commands = {
			refresh = doRefresh,
			addLayer = doAddLayer,
			removeLayer = doRemoveLayer,
			toggleRecording = doToggleRecording,
			exportClip = doExportClip,
			togglePathRecord = doTogglePathRecord,
			toggleFreecam = doToggleFreecam,
			takeScreenshot = doScreenshot,
			saveShot = doSaveShot,
			loadShot = doLoadShot,
		},
		pathKeys = pathRecorder.keys,
		pathRecording = false,
		pathSampleHz = pathRecorder.sampleHz,
		pathTruncated = false,
		pathOffset = pathTimeOffset,
		section = "overview",
		notices = {},
		files = {},
		loadedFiles = {},
		shotFiles = {},
		shotName = "shot",
		clipName = "clip",
		clipStart = 0,
		clipEnd = 0,
		browserFilter = "",
		cameraMode = "manual",
		ridingFreecam = false,
		flySpeed = 0,
		framesPerSecond = 0,
		syncErrors = 0,
		errorCount = 0,
		lastError = "",
		canControlReplays = true,
		canWriteReplays = false,
		canWriteFiles = false,
		canScreenshot = false,
		recordTargetSeconds = recordTargetSeconds,
		pathMaxKeys = pathMaxKeys,
		pathBlend = pathBlend,
		layerCap = layerCap,
		settingsDirty = false,
	}
	return state
end
