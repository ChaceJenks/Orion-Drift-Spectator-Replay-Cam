--!strict
--[[
	The camera's panel, rendered from onGui() while the Current Camera panel is
	open (F3 by default).

	What the widget vocabulary actually allows, since that shapes the design:

	* There is no tab bar, menu bar, colour, theme, font or image API. The whole
		vocabulary is text / separator / tree / combo / listbox / table plus four
		game-specific widgets. So the "menu" here is a row of `selectable` items
		inside a horizontal group - the closest thing to a tab strip this API can
		express - and quality has to come from hierarchy, alignment, icons and
		spacing rather than styling.
	* Labels are widget identities. Every repeated block is wrapped in pushId /
		popId, or two layer rows would share widget state and drive each other.
	* Widgets return their new value and there is no event queue, so widgets write
		straight into the shared model. Only side-effecting actions (talking to the
		client, touching disk) go through app.commands.
	* Icons are FontAwesome glyph strings concatenated into labels, read through a
		pcall cache so a build without the `Icon` global degrades to plain text
		instead of erroring every frame.
]]

local Types = require("types")
local Util = require("util")
local VecMath = require("vecmath")
local Layers = require("replaylayers")
local Fly = require("flycamera")

type AppState = Types.AppState
type Layer = Types.Layer
type Notice = Types.Notice
type FlySettings = Types.FlySettings
type PathKey = Types.PathKey

local Ui = {}

---- Icons ---------------------------------------------------------------------

local glyphCache: { [string]: string } = {}
local iconAvailable: boolean? = nil

-- Reads one FontAwesome glyph, falling back to no icon at all if this build does
-- not expose `Icon`. Cached, so the pcall is paid once per glyph name rather than
-- once per frame per label.
local function glyph(name: string): string
	local cached = glyphCache[name]
	if cached ~= nil then
		return cached
	end
	if iconAvailable == false then
		glyphCache[name] = ""
		return ""
	end
	local ok, value = pcall(function()
		return (Icon :: any)[name]
	end)
	local result = if ok and type(value) == "string" and #(value :: string) > 0 then value :: string else ""
	if #result == 0 then
		iconAvailable = false
	end
	glyphCache[name] = result
	return result
end

local function glyphed(name: string, text: string): string
	local mark = glyph(name)
	if #mark == 0 then
		return text
	end
	return mark .. " " .. text
end

---- Layout helpers ------------------------------------------------------------

local function markDirty(app: AppState)
	app.settingsDirty = true
end

local function space()
	Gui.spacing()
end

local function rule(title: string)
	Gui.separatorText(title)
end

-- A dropdown whose begin/end pair lives entirely inside this function, so it
-- cannot be left unbalanced by a later edit to one of the option lists.
local function combo(label: string, current: string, options: { string }): string
	local result = current
	if Gui.beginCombo(label, current) then
		for _, option in options do
			-- Only the selected row carries a marker, as ImGui convention goes.
			local rowLabel = if option == current then glyphed("Check", option) else "    " .. option
			if Gui.selectable(rowLabel, option == current) then
				result = option
			end
		end
		Gui.endCombo()
	end
	return result
end

local function checkbox(app: AppState, label: string, value: boolean): boolean
	local result = Gui.checkbox(label, value)
	if result ~= value then
		markDirty(app)
	end
	return result
end

local function slider(app: AppState, label: string, value: number, low: number, high: number): number
	local result = Gui.sliderFloat(label, value, low, high)
	if result ~= value then
		markDirty(app)
	end
	return result
end

-- Arity trap: dragFloat is (label, value, dragSpeed, min, max), while sliderFloat
-- has no drag speed. Getting this wrong is a runtime error, not a type error,
-- because the widget set is untyped at the boundary.
local function drag(label: string, value: number, speed: number, low: number, high: number, tooltip: string?): number
	local result = Gui.dragFloat(label, value, speed, low, high)
	if tooltip ~= nil then
		Gui.setItemTooltip(tooltip :: string)
	end
	return result
end

-- A text progress bar; there is no progress widget in this API.
local function bar(fraction: number, width: number): string
	-- Nothing today can hand this a NaN, but a NaN reaching string.rep throws inside
	-- onGui, and a throwing panel makes the whole camera unusable. One clamp here
	-- means the panel cannot be taken down by a bad ratio from any caller.
	local safe = if Util.isFiniteNumber(fraction) then Util.clamp(fraction, 0, 1) else 0
	local filled = math.floor(safe * width + 0.5)
	return string.rep("#", filled) .. string.rep("-", math.max(0, width - filled))
end

-- A one-line speed profile for a captured move, since there is no graph widget
-- that is safe to write to. Block-drawing glyphs are avoided: the panel font is
-- the FontAwesome set and may not carry them.
local SPARK_RAMP = ".:-=+*#%@"

local function sparkline(keys: { PathKey }, samples: number): string
	if #keys < 2 then
		return ""
	end
	local duration = keys[#keys].t - keys[1].t
	if duration <= 0 then
		return ""
	end

	local bucket = duration / samples
	local speeds: { number } = {}
	local peak = 0.001
	local index = 2
	for slot = 1, samples do
		local to = keys[1].t + slot * bucket
		local distance = 0.0
		while index <= #keys and keys[index].t <= to do
			local a = keys[index - 1]
			local b = keys[index]
			distance += VecMath.length(a.x - b.x, a.y - b.y, a.z - b.z)
			index += 1
		end
		local speed = distance / bucket
		speeds[slot] = speed
		if speed > peak then
			peak = speed
		end
	end

	local cells: { string } = {}
	for slot = 1, samples do
		local level = math.floor((speeds[slot] / peak) * (#SPARK_RAMP - 1) + 0.5)
		table.insert(cells, string.sub(SPARK_RAMP, level + 1, level + 1))
	end
	return table.concat(cells)
end

---- Menu ----------------------------------------------------------------------

local SECTIONS = {
	{ id = "overview", icon = "Th", title = "Overview" },
	{ id = "replays", icon = "LayerGroup", title = "Replays" },
	{ id = "record", icon = "Circle", title = "Record" },
	{ id = "camera", icon = "Camera", title = "Camera" },
	{ id = "motion", icon = "ArrowsAlt", title = "Motion" },
	{ id = "shot", icon = "Save", title = "Shot" },
	{ id = "keys", icon = "Keyboard", title = "Keys" },
	{ id = "debug", icon = "Cog", title = "Debug" },
}

-- Badges make state legible from across the room: how many replays are stacked,
-- whether the recorder is hot, whether anything has gone wrong.
local function sectionBadge(app: AppState, id: string): string
	if id == "replays" and #app.layers > 0 then
		return string.format(" (%d)", #app.layers)
	elseif id == "record" and app.record.phase == "recording" then
		return " (!)"
	elseif id == "motion" and #app.pathKeys > 0 then
		return string.format(" (%d)", #app.pathKeys)
	elseif id == "debug" and (app.errorCount > 0 or app.syncErrors > 0) then
		return " (!)"
	end
	return ""
end

local function drawMenu(app: AppState)
	Gui.beginHorizontal("##replaycam-menu")
	for _, section in SECTIONS do
		Gui.pushId(section.id)
		local label = glyphed(section.icon, section.title) .. sectionBadge(app, section.id)
		if Gui.selectable(label, app.section == section.id) then
			app.section = section.id
		end
		Gui.popId()
	end
	Gui.endHorizontal()
end

---- Scrubber ------------------------------------------------------------------

-- The timeline widget is the nicest way to scrub and the least certain to exist,
-- so it is pcall'd with a plain slider as fallback rather than losing the panel
-- for a whole session over one missing widget.
local function drawScrubber(app: AppState, start: number, finish: number)
	local comp = app.comp
	local scrubbed: number? = nil
	local ok, value = pcall(function()
		return Gui.timeline("##replaycam-timeline", comp.masterT, start, finish, 0)
	end)
	if ok and type(value) == "number" then
		scrubbed = value :: number
	else
		if finish > start then
			local slid = Gui.sliderFloat("##scrub", comp.masterT, start, finish)
			if slid ~= comp.masterT then
				scrubbed = slid
			end
		else
			Gui.text("Nothing to scrub yet.")
		end
	end
	if scrubbed ~= nil then
		comp.masterT = Layers.sanitizeMasterTime(scrubbed :: number, comp, app.layers)
	end

	Gui.text("Clip range")
	local rangeOk, rangeValue = pcall(function()
		return Gui.rangeSlider("##cliprange", Vec2.new(app.clipStart, app.clipEnd), start, finish)
	end)
	if rangeOk and rangeValue ~= nil then
		local range = rangeValue :: { x: number, y: number }
		app.clipStart = range.x
		app.clipEnd = range.y
	else
		app.clipStart = drag("from", app.clipStart, 0.1, start, finish)
		app.clipEnd = drag("to", app.clipEnd, 0.1, start, finish)
	end
	if app.clipEnd < app.clipStart then
		app.clipEnd = app.clipStart
	end
	Gui.text(string.format(
		"clip %s to %s  (%s)",
		Util.formatTime(app.clipStart),
		Util.formatTime(app.clipEnd),
		Util.formatTime(math.max(0, app.clipEnd - app.clipStart))
	))
end

---- Notices -------------------------------------------------------------------

local function drawNotices(app: AppState, limit: number)
	if #app.notices == 0 then
		Gui.text("Nothing to report.")
		return
	end
	if Gui.smallButton(glyphed("Times", "Clear")) then
		app.notices = {}
	end
	for index = 1, math.min(#app.notices, limit) do
		local notice: Notice = app.notices[index]
		local mark = if notice.kind == "info" then glyph("InfoCircle") else glyph("ExclamationTriangle")
		if #mark == 0 then
			mark = notice.kind
		end
		Gui.text(string.format("%s %s", mark, notice.text))
	end
end

---- Overview ------------------------------------------------------------------

-- Turns the current state into the single next action. In a tool you only look at
-- between takes, that is worth more than any amount of status readout.
local function nextStep(app: AppState): string
	local comp = app.comp
	if #app.layers == 0 then
		return "Open Replays and click a file to stack it into the world."
	end
	if Layers.usableCount(app.layers) == 0 then
		return "Nothing is driven yet - press Refresh on the Replays page to re-resolve handles."
	end
	if not comp.playing and comp.masterT <= 0 then
		return "Press Play, or drag the timeline."
	end
	if #app.layers < 2 then
		return "Add a second replay: that is where the overlay starts to pay for itself."
	end
	if comp.syncMode == "independent" then
		return "Set Clock back to masterClock to lock the layers together."
	end
	if #app.pathKeys == 0 then
		return "Capture a move on the Motion page whenever you like a framing."
	end
	return "Save the whole setup as a shot from the Shot page."
end

local function drawOverview(app: AppState)
	local comp = app.comp
	local start, finish = Layers.effectiveWindow(comp, app.layers)
	local fraction = Layers.progress(comp, app.layers)

	rule("Transport")
	if Gui.button(if comp.playing then glyphed("Pause", "Pause") else glyphed("Play", "Play")) then
		comp.playing = not comp.playing
	end
	Gui.sameLine()
	if Gui.button(glyphed("Stop", "Stop")) then
		comp.playing = false
		comp.masterT = start
	end
	Gui.sameLine()
	if Gui.button(glyphed("Undo", "To start")) then
		comp.masterT = start
	end
	Gui.sameLine()
	if Gui.button(if app.record.phase == "recording" then glyphed("Stop", "Stop record") else glyphed("Circle", "Record")) then
		app.commands.toggleRecording()
	end

	Gui.text(string.format(
		"[%s] %3d%%   %s / %s",
		bar(fraction, 26),
		math.floor(fraction * 100 + 0.5),
		Util.formatTime(comp.masterT),
		Util.formatTime(finish)
	))

	Gui.text("Speed")
	for _, speed in { -1, -0.5, 0.25, 0.5, 1, 2, 4 } do
		if Gui.smallButton(string.format("%gx", speed)) then
			comp.speed = speed
		end
		Gui.sameLine()
	end
	Gui.newLine()
	comp.speed = slider(app, "##speed", comp.speed, -4, 4)
	comp.loopMode = combo("At the end", comp.loopMode, { "loop", "stop", "holdEnd" })
	comp.syncMode = combo("Clock", comp.syncMode, { "masterClock", "independent" })
	Gui.setItemTooltip(
		"masterClock   every loaded replay is driven from this one time value, which is\n"
			.. "              what keeps the overlay in step while you scrub, pause or re-speed.\n"
			.. "independent hands control back to the client; the layers drift apart."
	)

	rule("Scrub")
	drawScrubber(app, start, finish)

	rule("Stacked replays")
	if #app.layers == 0 then
		Gui.text("None yet.")
	else
		if Gui.beginTable("##overview-layers", 4) then
			Gui.tableSetupColumn("Replay")
			Gui.tableSetupColumn("Length")
			Gui.tableSetupColumn("Offset")
			Gui.tableSetupColumn("Status")
			Gui.tableHeadersRow()
			for _, layer in app.layers do
				Gui.tableNextRow()
				Gui.tableNextColumn()
				Gui.text(layer.label)
				Gui.tableNextColumn()
				Gui.text(Util.formatTime(layer.duration))
				Gui.tableNextColumn()
				Gui.text(string.format("%+.2fs", layer.offset))
				Gui.tableNextColumn()
				Gui.text(if layer.missing
					then "not loaded"
					else if layer.handle == nil then "resolving" else glyphed("Check", "driven"))
			end
			Gui.endTable()
		end
	end

	rule("Next")
	Gui.text(nextStep(app))

	if #app.notices > 0 then
		rule("Latest")
		drawNotices(app, 4)
	end
end

---- Replays -------------------------------------------------------------------

local function drawLayerRow(app: AppState, layer: Layer, index: number)
	Gui.pushId(string.format("%d-%s", index, layer.file))

	local mark = if layer.missing then glyph("ExclamationTriangle") else if layer.handle == nil then glyph("Clock") else glyph("Check")
	Gui.text(if #mark > 0 then string.format("%s %s", mark, layer.label) else layer.label)

	Gui.text(string.format(
		"%s long   at %s   recorded %s",
		Util.formatTime(layer.duration),
		Util.formatTime(Layers.layerTime(layer, app.comp.masterT) or 0),
		if layer.startTicks > 0 then Util.stampFromTicks(layer.startTicks) else "unknown"
	))

	layer.offset = drag(
		"offset",
		layer.offset,
		0.1,
		-3600,
		3600,
		"Seconds of this replay's own timeline at clock 0.\n"
			.. "Negative means it sits on its first frame until the clock reaches it."
	)
	local overflow = combo("when finished", layer.overflow, { "hold", "loop" })
	if overflow ~= layer.overflow then
		layer.overflow = overflow
	end
	Gui.setItemTooltip("hold stays on the last frame. loop wraps back to the first.")

	if Gui.smallButton(glyphed("Times", "remove")) then
		app.commands.removeLayer(layer.file)
	end
	Gui.sameLine()
	if Gui.smallButton(glyphed("Undo", "zero")) then
		layer.offset = 0
	end
	Gui.separator()
	Gui.popId()
end

local function drawBrowser(app: AppState)
	if Gui.button(glyphed("Sync", "Refresh")) then
		app.commands.refresh()
	end
	Gui.sameLine()
	Gui.text(string.format("%d on disk   %d loaded", #app.files, #app.loadedFiles))

	app.browserFilter = Gui.inputText(glyphed("Search", "filter"), app.browserFilter)

	local visible: { string } = {}
	for _, file in app.files do
		if Util.containsCaseless(Util.basename(file), app.browserFilter) then
			table.insert(visible, file)
		end
	end
	if #visible == 0 then
		Gui.text(if #app.files == 0
			then "The replays folder is empty. Record something from the Record page."
			else "No file matches that filter.")
	else
		if #visible > 60 then
			Gui.text(string.format("%d matches, showing 60. Narrow the filter.", #visible))
		end
		if Gui.beginListBox("##replaybrowser") then
			for index = 1, math.min(#visible, 60) do
				local file = visible[index]
				if Gui.selectable(glyphed("Plus", Util.basename(file)), false) then
					app.commands.addLayer(file)
				end
			end
			Gui.endListBox()
		end
		Gui.setItemTooltip("Click to stack this replay into the world.")
	end
end

local function drawReplays(app: AppState)
	if #app.layers == 0 then
		Gui.text("Nothing stacked. Pick files below; every one of them renders in the")
		Gui.text("same world at the same time, driven by the clock on the Overview page.")
	else
		if Gui.button(glyphed("Compass", "Align by recorded time")) then
			if Layers.alignToWallclock(app.layers) == 0 then
				table.insert(app.notices, {
					kind = "warn",
					text = "No replay reported a start time, so there was nothing to align to.",
				})
			end
		end
		Gui.setItemTooltip(
			"Places each replay where it actually was on the server clock, using the\n"
				.. "timestamp of its first frame. Correct for several recordings of one match."
		)
		Gui.sameLine()
		if Gui.button(glyphed("Undo", "Start them together")) then
			Layers.resetOffsets(app.layers)
		end
		Gui.setItemTooltip("All layers begin at clock 0, ignoring when they were recorded.")
		space()

		for index, layer in app.layers do
			drawLayerRow(app, layer, index)
		end
	end

	rule("Add a replay")
	if #app.layers >= app.layerCap then
		Gui.text(string.format("At the cap of %d stacked replays. Remove one first.", app.layerCap))
		if Gui.button(glyphed("Sync", "Refresh")) then
			app.commands.refresh()
		end
	else
		drawBrowser(app)
	end
end

---- Record -------------------------------------------------------------------

local function drawRecord(app: AppState)
	local record = app.record
	local recording = record.phase == "recording"

	if Gui.button(if recording then glyphed("Stop", "Stop recording") else glyphed("Circle", "Start recording")) then
		app.commands.toggleRecording()
	end
	Gui.sameLine()
	if recording then
		Gui.text(if record.targetSeconds > 0
			then string.format("%s of %s", Util.formatTime(record.elapsed), Util.formatTime(record.targetSeconds))
			else Util.formatTime(record.elapsed))
		if record.targetSeconds > 0 then
			space()
			Gui.text(bar(record.elapsed / record.targetSeconds, 30))
		end
	else
		Gui.text(if record.targetSeconds > 0
			then string.format("stops by itself at %s", Util.formatTime(record.targetSeconds))
			else "runs until you stop it")
	end

	if not app.canControlReplays then
		space()
		Gui.text(glyphed("ExclamationTriangle", "The client will refuse to record."))
		Gui.text("Turn on Luau replay control in the spectator options, then Refresh.")
	end

	app.recordTargetSeconds = slider(app, "recording length", app.recordTargetSeconds, 0, 600)
	Gui.setItemTooltip("0 records until you stop it by hand.")

	if #record.currentFile > 0 then
		space()
		Gui.text("last recording: " .. record.currentFile)
	end
	if #record.lastError > 0 then
		Gui.text("last error: " .. record.lastError)
	end

	rule("Export a clip")
	app.clipName = Gui.inputText("clip name", app.clipName)
	if Gui.button(glyphed("Download", "Export clip as .a2replay")) then
		app.commands.exportClip()
	end
	Gui.setItemTooltip(
		"Writes the marked range as a new replay file, re-encoded in the current format.\n"
			.. "Set the range on the Overview page."
	)
	Gui.text(if #app.clipName == 0
		then "Name it, set the range on the Overview page, then export."
		else "The clip shows up in the Replays browser after the next refresh.")
end

---- Camera -------------------------------------------------------------------

local function drawCamera(app: AppState)
	local settings: FlySettings = app.settings

	Gui.text(string.format(
		"%s  %.0f, %.0f, %.0f    yaw %.0f  pitch %.0f    %.0f cm/s",
		glyphed("Crosshairs", "pos"),
		app.fly.x,
		app.fly.y,
		app.fly.z,
		app.fly.yaw,
		app.fly.pitch,
		app.flySpeed
	))

	if Gui.button(if app.ridingFreecam then glyphed("Times", "Take control back") else glyphed("Compass", "Ride the built-in Free Cam")) then
		app.commands.toggleFreecam()
	end
	Gui.setItemTooltip(
		"Hands the view to anotheraxiom.freecam so you can use the client's own flying\n"
			.. "controls. Key capture and motion playback keep working from that pose."
	)
	Gui.sameLine()
	if Gui.smallButton(glyphed("Stop", "Freeze")) then
		Fly.stopMotion(app.fly)
	end
	Gui.setItemTooltip("Drops all momentum without moving, to hold a framing rock steady.")

	rule("Feel")
	settings.moveSpeed = slider(app, "move speed", settings.moveSpeed, 10, 20000)
	Gui.setItemTooltip("Centimetres per second. The stations are a few hundred metres across.")
	settings.boostMultiplier = slider(app, "boost", settings.boostMultiplier, 1, 20)
	settings.fineMultiplier = slider(app, "fine", settings.fineMultiplier, 0.005, 1)
	settings.lookSensitivity = slider(app, "look", settings.lookSensitivity, 0.01, 2)
	settings.fov = slider(app, "field of view", settings.fov, 20, 150)

	rule("Smoothing")
	settings.inertia = checkbox(app, "glide to a stop", settings.inertia)
	settings.dampingTime = slider(app, "stop easing", settings.dampingTime, 0.01, 2)
	settings.positionSmoothing = slider(app, "position", settings.positionSmoothing, 0, 2)
	settings.rotationSmoothing = slider(app, "rotation", settings.rotationSmoothing, 0, 2)
	Gui.setItemTooltip("Seconds the client takes to catch up with where you put the camera.")

	rule("Look")
	settings.freeLook = checkbox(app, "look without holding the mouse", settings.freeLook)
	Gui.setItemTooltip(
		"Off means look is only read while the right mouse button is held. The API\n"
			.. "cannot report whether the panel wants the mouse, so holding the button is\n"
			.. "what keeps a panel drag from spinning the camera."
	)
	settings.alignRoll = checkbox(app, "level to local gravity", settings.alignRoll)
	Gui.setItemTooltip("Uses the station's local up. Where the client reports no gravity, world up is used.")
	settings.followBuiltInFreecam = checkbox(app, "start by riding the Free Cam", settings.followBuiltInFreecam)
end

---- Motion -------------------------------------------------------------------

local function drawMotion(app: AppState)
	app.cameraMode = combo("Camera source", app.cameraMode, { "manual", "followPath", "blend" })
	Gui.setItemTooltip(
		"manual       your keys drive the camera.\n"
			.. "followPath  the captured keyframes drive it, tied to the clock.\n"
			.. "blend       eases between the two, so you can fly in and hand over."
	)
	if app.cameraMode == "blend" then
		app.pathBlend = slider(app, "hand over to path", app.pathBlend, 0, 1)
	end

	if Gui.button(if app.pathRecording then glyphed("Stop", "Stop capturing") else glyphed("Video", "Capture camera keys")) then
		app.commands.togglePathRecord()
	end
	Gui.sameLine()
	local duration = if #app.pathKeys > 0 then app.pathKeys[#app.pathKeys].t else 0
	Gui.text(string.format("%d keys over %s", #app.pathKeys, Util.formatTime(duration)))

	if app.pathTruncated then
		Gui.text(glyphed("ExclamationTriangle", string.format("hit the %d key cap; the rest was dropped", app.pathMaxKeys)))
	end
	if #app.pathKeys == 0 and app.cameraMode ~= "manual" then
		Gui.text("No keyframes yet, so this mode holds the camera still.")
	end

	local trace = sparkline(app.pathKeys, 32)
	if #trace > 0 then
		space()
		Gui.text(string.format("%s %s  %s", glyphed("ChartLine", "speed"), trace, Util.formatTime(duration)))
		Gui.setItemTooltip("Speed along the captured path, slowest on the left.")
	end

	app.pathOffset = drag(
		"path time offset",
		app.pathOffset,
		0.1,
		-600,
		600,
		"Shifts the move against the clock, so a shot can be re-timed without re-flying it."
	)
	app.pathSampleHz = slider(app, "capture rate", app.pathSampleHz, 5, 120)
	Gui.setItemTooltip("Keys per second while capturing. 30 is close enough to the replay frame rate.")
end

---- Shot ---------------------------------------------------------------------

local function drawShot(app: AppState)
	Gui.text("One file holds the stacked replays, their alignment, the clip range and")
	Gui.text("the captured camera keys. Replay files are stored by name, so the replays")
	Gui.text("have to be in the same folder on another machine.")

	app.shotName = Gui.inputText("shot name", app.shotName)
	if Gui.button(glyphed("Save", "Save shot")) then
		app.commands.saveShot(app.shotName)
	end
	Gui.sameLine()
	if Gui.button(glyphed("Sync", "Refresh list")) then
		app.commands.refresh()
	end

	if not app.canWriteFiles then
		space()
		Gui.text(glyphed("ExclamationTriangle", "This build does not expose package files, so shots cannot be stored."))
	elseif #app.shotFiles == 0 then
		space()
		Gui.text("No saved shots yet.")
	else
		space()
		if Gui.beginListBox("##shots") then
			for _, shotFile in app.shotFiles do
				if Gui.selectable(glyphed("FolderOpen", shotFile), false) then
					app.commands.loadShot(shotFile)
				end
			end
			Gui.endListBox()
		end
		Gui.setItemTooltip("Click to restore its layers and camera move.")
		Gui.text(string.format(
			"%d shot%s stored in the package folder.",
			#app.shotFiles,
			if #app.shotFiles == 1 then "" else "s"
		))
	end
end

---- Keys ---------------------------------------------------------------------

local function keyRow(action: string, keys: string)
	Gui.text(string.format("%-24s %s", action, keys))
end

local function drawKeys()
	rule("Fly")
	keyRow("move", "W  A  S  D")
	keyRow("up / down", "E  Q")
	keyRow("boost / fine", "Left Shift / Left Control")
	keyRow("look", "hold Right mouse + move")
	keyRow("freeze in place", "Backspace")

	rule("Transport")
	keyRow("play / pause", "Space")
	keyRow("step one frame", "Comma  and  Period")
	keyRow("jump to the start", "Home")

	rule("Actions")
	keyRow("start / stop recording", "R")
	keyRow("export the clip", "C")
	keyRow("capture camera keys", "P")
	keyRow("cycle camera source", "K")
	keyRow("ride the built-in Free Cam", "F")
	keyRow("screenshot", "V")
	space()
	Gui.text("Keys register only while this camera is the active one, and never while a")
	Gui.text("text box has focus. The spectator app itself owns F1 to F4.")
end

---- Debug --------------------------------------------------------------------

local function capabilityMark(allowed: boolean): string
	local mark = if allowed then glyph("Check") else glyph("EyeSlash")
	if #mark == 0 then
		return if allowed then "yes" else "no"
	end
	return mark
end

local function capabilityLine(label: string, allowed: boolean): string
	return string.format("%s %s", capabilityMark(allowed), label)
end

local function drawDebug(app: AppState)
	local comp = app.comp
	local windowStart, windowFinish = Layers.naturalWindow(app.layers)

	Gui.text(string.format(
		"%.0f fps   clock %.4fs   sync %s   loop %s   speed %.2fx",
		app.framesPerSecond,
		comp.masterT,
		comp.syncMode,
		comp.loopMode,
		comp.speed
	))
	Gui.text(string.format(
		"window %.2f .. %.2f   user clip %.2f .. %.2f   marked %.2f .. %.2f",
		windowStart,
		windowFinish,
		comp.rangeStart,
		comp.rangeEnd,
		app.clipStart,
		app.clipEnd
	))
	Gui.text(string.format(
		"%s   %s   %s   %s",
		capabilityLine("replay control", app.canControlReplays),
		capabilityLine("replay writes", app.canWriteReplays),
		capabilityLine("package files", app.canWriteFiles),
		capabilityLine("screenshots", app.canScreenshot)
	))
	Gui.text(string.format("sync errors %d   script errors %d", app.syncErrors, app.errorCount))
	if #app.lastError > 0 then
		Gui.text("last: " .. app.lastError)
	end

	rule("Layer internals")
	if #app.layers == 0 then
		Gui.text("No layers.")
	end
	for index, layer in app.layers do
		Gui.text(string.format(
			"[%d] %-24s offset %+.3f  dur %.2f  ticks %d  %s",
			index,
			layer.label,
			layer.offset,
			layer.duration,
			layer.startTicks,
			if layer.missing then "MISSING" else if layer.handle == nil then "unresolved" else "ok"
		))
	end

	rule("Notices")
	drawNotices(app, 15)
end

---- Entry point --------------------------------------------------------------

--[[
	Renders the panel. main.luau calls this inside a pcall and counts failures, so
	a widget missing from some future build produces one warning instead of leaving
	a half-drawn panel forever.
]]
function Ui.draw(app: AppState)
	drawMenu(app)
	Gui.separator()

	if app.section == "replays" then
		drawReplays(app)
	elseif app.section == "record" then
		drawRecord(app)
	elseif app.section == "camera" then
		drawCamera(app)
	elseif app.section == "motion" then
		drawMotion(app)
	elseif app.section == "shot" then
		drawShot(app)
	elseif app.section == "keys" then
		drawKeys()
	elseif app.section == "debug" then
		drawDebug(app)
	else
		drawOverview(app)
	end
end

return Ui
