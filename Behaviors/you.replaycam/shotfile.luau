--!strict
--[[
	Shot files.

	A .a2replay records the *game*. It has no notion of your camera, and nothing
	about which replays you stacked on top of each other. A shot file records
	both: the layer stack, the alignment, the clip range, and the recorded camera
	move. Saving that is what turns "I set up a nice overlay" into something you
	can hand to someone else or reopen next week.

	Two rules this module exists to enforce:

	* **Filenames are untrusted input.** They come from a text box and are joined
	  onto a path handed to LuauFile, so every name is reduced to a safe token.
	  Without this, typing "../.." escapes the shots folder.
	* **Parsed JSON is untrusted input.** A shot file on disk may have been
	  hand-edited or written by an older version. Everything read back is
	  range-checked and defaulted, and a malformed file reports one clear error
	  instead of throwing inside the tick loop.
]]

local Types = require("types")
local Util = require("util")
local Layers = require("replaylayers")

type Shot = Types.Shot
type Layer = Types.Layer
type Composition = Types.Composition
type CameraPath = Types.CameraPath
type PathKey = Types.PathKey

-- Injected so the encode/decode round trip can be tested without the client.
-- main.luau passes the real LuauJson.
export type JsonApi = {
	serialize: (value: any, pretty: boolean) -> string,
	parse: (text: string) -> any,
}

local ShotFile = {}

local SHOT_VERSION = 1
local MAX_PATH_KEYS = 50000

-- Exposed so a caller clamping a config value cannot drift from the encoder's
-- own cap.
ShotFile.MAX_PATH_KEYS = MAX_PATH_KEYS

---- Filenames ------------------------------------------------------------------

-- Reduces user text to something safe to append to a path. Keeps letters,
-- digits, dash, underscore and dot; collapses everything else to underscore.
function ShotFile.sanitizeFileName(raw: string): string
	local result = {}
	local previousWasUnderscore = false
	for i = 1, #(raw or "") do
		local character = string.sub(raw, i, i)
		if string.find(character, "^[%w%-_]$") then
			table.insert(result, character)
			previousWasUnderscore = false
		elseif character == "." then
			-- Dots are allowed but never at the start, so a name can never become
			-- ".." or a hidden-only suffix.
			if #result > 0 then
				table.insert(result, ".")
			end
		elseif not previousWasUnderscore then
			table.insert(result, "_")
			previousWasUnderscore = true
		end
	end
	local name = table.concat(result)
	-- Reject the only remaining hazard: a name that is nothing but dots.
	local onlyDots = string.match(name, "^%.+$") ~= nil
	if #name == 0 or onlyDots then
		return "shot"
	end
	if #name > 64 then
		name = string.sub(name, 1, 64)
	end
	return name
end

function ShotFile.shotPath(name: string): string
	return "shots/" .. ShotFile.sanitizeFileName(name) .. ".json"
end

---- Building a shot from live state -------------------------------------------

function ShotFile.capture(
	name: string,
	comp: Composition,
	layers: { Layer },
	path: CameraPath?
): Shot
	local layerSpecs: { { file: string, label: string, offset: number, overflow: string } } = {}
	for _, layer in layers do
		table.insert(layerSpecs, {
			file = layer.file,
			label = layer.label,
			offset = layer.offset,
			overflow = layer.overflow,
		})
	end

	local pathCopy: CameraPath? = nil
	if path ~= nil and #path.keys > 0 then
		local keys: { PathKey } = {}
		for index = 1, math.min(#path.keys, MAX_PATH_KEYS) do
			keys[index] = path.keys[index]
		end
		pathCopy = { sampleHz = path.sampleHz, keys = keys, offset = path.offset }
	end

	return {
		version = SHOT_VERSION,
		name = name,
		syncMode = comp.syncMode,
		alignMode = comp.alignMode,
		loopMode = comp.loopMode,
		speed = comp.speed,
		rangeStart = comp.rangeStart,
		rangeEnd = comp.rangeEnd,
		layers = layerSpecs,
		path = pathCopy,
	}
end

---- Serialisation --------------------------------------------------------------

function ShotFile.encode(shot: Shot, json: JsonApi): string
	local payload: { [string]: any } = {
		version = shot.version,
		name = shot.name,
		syncMode = shot.syncMode,
		alignMode = shot.alignMode,
		loopMode = shot.loopMode,
		speed = shot.speed,
		rangeStart = shot.rangeStart,
		rangeEnd = shot.rangeEnd,
		layers = shot.layers,
	}
	if shot.path ~= nil then
		payload.path = {
			sampleHz = (shot.path :: CameraPath).sampleHz,
			offset = (shot.path :: CameraPath).offset,
			keys = (shot.path :: CameraPath).keys,
		}
	end
	return json.serialize(payload, true)
end

local function readNumberTable(raw: any, keys: { string }): { [string]: number }?
	if type(raw) ~= "table" then
		return nil
	end
	local out: { [string]: number } = {}
	for _, key in keys do
		local value = (raw :: { [string]: any })[key]
		if type(value) ~= "number" or not Util.isFiniteNumber(value :: number) then
			return nil
		end
		out[key] = value :: number
	end
	return out
end

-- Validates and repairs one keyframe entry.
local function decodeKey(raw: any): PathKey?
	if type(raw) ~= "table" then
		return nil
	end
	-- The pose and the quaternion are required, because there is no sensible value
	-- to invent for them. The field of view is not: a hand-written or older entry
	-- that leaves it out is repaired below rather than thrown away.
	local numbers = readNumberTable(raw, { "t", "x", "y", "z", "rx", "ry", "rz", "rw" })
	if numbers == nil then
		return nil
	end
	local entry = raw :: { [string]: any }
	return {
		t = numbers["t"],
		x = numbers["x"],
		y = numbers["y"],
		z = numbers["z"],
		rx = numbers["rx"],
		ry = numbers["ry"],
		rz = numbers["rz"],
		rw = numbers["rw"],
		fov = Util.num(entry["fov"], 90, 1, 179),
	}
end

local function decodePath(raw: any): CameraPath?
	if type(raw) ~= "table" then
		return nil
	end
	local table_ = raw :: { [string]: any }
	local rawKeys = table_["keys"]
	if type(rawKeys) ~= "table" then
		return nil
	end
	local keys: { PathKey } = {}
	local list = rawKeys :: { any }
	for index = 1, math.min(#list, MAX_PATH_KEYS) do
		local key = decodeKey(list[index])
		if key ~= nil then
			table.insert(keys, key)
		end
	end
	if #keys == 0 then
		return nil
	end
	-- Sorting is not optional: playback binary-searches on t.
	table.sort(keys, function(a: PathKey, b: PathKey): boolean
		return a.t < b.t
	end)
	-- A non-positive rate means the file is broken, not that the caller wanted 1 Hz,
	-- so it takes the same default Path.newRecorder would give rather than the
	-- bottom of the range.
	local sampleHz = Util.num(table_["sampleHz"], 30)
	if sampleHz <= 0 then
		sampleHz = 30
	end
	return {
		sampleHz = Util.clamp(sampleHz, 1, 240),
		offset = Util.num(table_["offset"], 0),
		keys = keys,
	}
end

--[[
	Parses a shot file. Returns (shot, nil) on success or (nil, message) with a
	single human-readable reason. Never throws, whatever the text contains.
]]
function ShotFile.decode(text: string, json: JsonApi): (Shot?, string?)
	if type(text) ~= "string" or #text == 0 then
		return nil, "empty file"
	end

	local parsed, parseError = Util.try(function()
		return json.parse(text)
	end)
	if parseError ~= nil then
		return nil, "not valid json: " .. parseError
	end
	if type(parsed) ~= "table" then
		return nil, "file does not contain a shot object"
	end

	local root = parsed :: { [string]: any }
	local version = Util.int(root["version"], 0, 0, 1000)
	if version == 0 then
		return nil, "missing a version field"
	end
	if version > SHOT_VERSION then
		return nil, string.format("written by a newer version (v%d); this camera understands v%d", version, SHOT_VERSION)
	end

	local rawLayers = root["layers"]
	if type(rawLayers) ~= "table" then
		return nil, "missing a layers list"
	end

	local layerSpecs: { { file: string, label: string, offset: number, overflow: string } } = {}
	local list = rawLayers :: { any }
	for index = 1, #list do
		local entry = list[index]
		if type(entry) == "table" then
			local table_ = entry :: { [string]: any }
			local file = table_["file"]
			if type(file) == "string" and #(file :: string) > 0 then
				table.insert(layerSpecs, {
					file = Util.basename(file :: string),
					label = Util.str(table_["label"], Util.shortReplayName(file :: string)),
					offset = Util.num(table_["offset"], 0, -86400, 86400),
					overflow = Util.enum(table_["overflow"], { "hold", "loop" }, "hold"),
				})
			end
		end
	end

	local shot: Shot = {
		version = version,
		name = Util.str(root["name"], "untitled"),
		syncMode = Util.enum(root["syncMode"], { "masterClock", "independent" }, "masterClock"),
		alignMode = Util.enum(root["alignMode"], { "relative", "wallclock" }, "relative"),
		loopMode = Util.enum(root["loopMode"], { "loop", "stop", "holdEnd" }, "loop"),
		speed = Util.num(root["speed"], 1, -16, 16),
		rangeStart = Util.num(root["rangeStart"], 0),
		rangeEnd = Util.num(root["rangeEnd"], 0),
		layers = layerSpecs,
		path = decodePath(root["path"]),
	}

	if #layerSpecs == 0 and shot.path == nil then
		return nil, "no layers and no camera path; nothing to restore"
	end

	return shot, nil
end

---- Applying a decoded shot ---------------------------------------------------

-- Writes the timing fields onto a live composition. Layer handles are NOT
-- touched here: loading files is main's job because it owns the Replay calls.
function ShotFile.applyComposition(shot: Shot, comp: Composition)
	comp.syncMode = shot.syncMode
	comp.alignMode = shot.alignMode
	comp.loopMode = shot.loopMode
	comp.speed = shot.speed
	comp.masterT = 0
	comp.playing = false
	if shot.rangeEnd > shot.rangeStart then
		comp.rangeStart = shot.rangeStart
		comp.rangeEnd = shot.rangeEnd
	else
		comp.rangeStart = 0
		comp.rangeEnd = 0
	end
end

-- Builds unbound layers from a shot; the handles get attached by
-- Layers.reconcile once the files are actually loaded.
function ShotFile.buildLayers(shot: Shot): { Layer }
	local layers: { Layer } = {}
	for _, spec in shot.layers do
		local layer = Layers.newLayer(spec.file, spec.label, 0, 0)
		layer.offset = spec.offset
		layer.overflow = spec.overflow
		layer.missing = true -- until a handle resolves
		table.insert(layers, layer)
	end
	return layers
end

return ShotFile
