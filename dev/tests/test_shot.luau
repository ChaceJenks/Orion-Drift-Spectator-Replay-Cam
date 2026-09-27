--!strict
--[[
	Tests for shot files: the names they get written under, and the round trip from
	live state to text and back.

	A shot file is the only part of this package that outlives the session, so the
	two properties worth defending are that it survives being read back (the whole
	point of saving) and that a hand-edited or foreign file cannot make the camera
	do anything unexpected - in particular that a file name inside a shot cannot
	reach outside the replays folder.
]]

local Harness = require("./harness")
local ShotFile = require("../pkg/shotfile")
local Layers = require("../pkg/replaylayers")
local Json = require("./jsonfake")
local Types = require("../pkg/types")

type Shot = Types.Shot
type Layer = Types.Layer
type CameraPath = Types.CameraPath
type PathKey = Types.PathKey
type JsonApi = ShotFile.JsonApi

Harness.suite("shotfile")

local json: JsonApi = {
	serialize = function(value: any, pretty: boolean): string
		return Json.serialize(value, pretty)
	end,
	parse = function(text: string): any
		return Json.parse(text)
	end,
}

---- File names ---------------------------------------------------------------

Harness.equal(ShotFile.sanitizeFileName("match3"), "match3", "a plain name is unchanged")
Harness.equal(ShotFile.sanitizeFileName("keep-dash_and9"), "keep-dash_and9", "dash, underscore and digits survive")
Harness.equal(ShotFile.sanitizeFileName(""), "shot", "an empty name gets a usable default")
Harness.equal(ShotFile.sanitizeFileName("   "), "_", "whitespace becomes a separator, not nothing")
Harness.equal(ShotFile.sanitizeFileName("..."), "shot", "dots alone are not a name")
Harness.equal(ShotFile.sanitizeFileName(".hidden"), "hidden", "a leading dot is dropped")
Harness.equal(ShotFile.sanitizeFileName("My Match 3!"), "My_Match_3_", "spaces and punctuation collapse")
Harness.equal(ShotFile.sanitizeFileName("a//b"), "a_b", "separators collapse to one underscore")
Harness.equal(ShotFile.sanitizeFileName("re:wild*?"), "re_wild_", "characters that mean something to a shell are replaced")

do
	-- The hazard this exists for: a shot file, or a text box, carrying a name that
	-- walks out of the shots folder.
	for _, hostile in { "../evil", "..\\..\\evil", "/etc/passwd", "a/../../b", "C:\\Windows\\x" } do
		local clean = ShotFile.sanitizeFileName(hostile)
		Harness.check(string.find(clean, "/", 1, true) == nil, "no forward slash survives in " .. hostile)
		Harness.check(string.find(clean, "\\", 1, true) == nil, "no backslash survives in " .. hostile)
		Harness.check(string.sub(clean, 1, 1) ~= ".", "no leading dot in " .. hostile)
		Harness.check(#clean > 0, "and the result is still a name: " .. hostile)
	end
end

do
	local long = string.rep("a", 200)
	Harness.equal(#ShotFile.sanitizeFileName(long), 64, "an absurdly long name is truncated rather than rejected")
end

Harness.equal(ShotFile.shotPath("match3"), "shots/match3.json", "shots live in their own folder")
Harness.equal(ShotFile.shotPath("../x"), "shots/_x.json", "including a name that tried to escape")

---- Capturing live state -----------------------------------------------------

do
	local comp = Layers.newComposition()
	comp.syncMode = "independent"
	comp.loopMode = "stop"
	comp.speed = 2
	comp.rangeStart = 4
	comp.rangeEnd = 9
	local layers: { Layer } = {
		Layers.newLayer("match1.a2replay", "Match 1", 12, 637000000000000),
		Layers.newLayer("match2", "Match 2", -3, 0),
	}
	layers[2].overflow = "loop"

	local shot = ShotFile.capture("round trip", comp, layers, nil)
	Harness.check(shot.version > 0, "a version is stamped")
	Harness.equal(shot.syncMode, "independent", "the composition is copied")
	Harness.equal(shot.loopMode, "stop", "including the loop mode")
	Harness.near(shot.speed, 2, "and the speed")
	Harness.near(shot.rangeStart, 4, "and the range")
	Harness.equal(#shot.layers, 2, "one entry per layer")
	Harness.equal(shot.layers[1].file, "match1.a2replay", "carrying the file name")
	Harness.equal(shot.layers[2].overflow, "loop", "and the overflow rule")
	Harness.isNil(shot.path, "no path means no path field")
end

do
	-- A captured path is copied, not aliased: the recorder keeps appending to its own
	-- key list, and a shot that shares that table would keep growing after it was
	-- written to disk.
	local keys: { PathKey } = {
		{ t = 0, x = 1, y = 2, z = 3, rx = 0, ry = 0, rz = 0, rw = 1, fov = 90 },
	}
	local path: CameraPath = { sampleHz = 24, keys = keys, offset = 1.5 }
	local comp = Layers.newComposition()
	local shot = ShotFile.capture("withpath", comp, {}, path)
	Harness.notNil(shot.path, "a path with keys is captured")
	if shot.path ~= nil then
		local captured = shot.path :: CameraPath
		Harness.near(captured.sampleHz, 24, "keeping the sample rate")
		Harness.near(captured.offset, 1.5, "and the offset")
		table.insert(keys, { t = 1, x = 9, y = 9, z = 9, rx = 0, ry = 0, rz = 0, rw = 1, fov = 90 })
		Harness.equal(#captured.keys, 1, "as a copy, so later recording does not change it")
	end

	local empty: { PathKey } = {}
	local emptyPath: CameraPath = { sampleHz = 30, keys = empty, offset = 0 }
	Harness.isNil(ShotFile.capture("emptypath", comp, {}, emptyPath).path, "a path with no keys is not stored")
end

---- Round trip ---------------------------------------------------------------

do
	local comp = Layers.newComposition()
	comp.alignMode = "wallclock"
	comp.speed = 0.5
	comp.rangeStart = 2
	comp.rangeEnd = 30
	local layers: { Layer } = { Layers.newLayer("C:\\replays\\final.a2replay", "Final", 60, 0) }
	layers[1].offset = -2.5
	local keys: { PathKey } = {
		{ t = 0, x = 100.5, y = -220.25, z = 180, rx = 0, ry = 0, rz = 0, rw = 1, fov = 90 },
		{ t = 0.5, x = 150.125, y = -200, z = 180.75, rx = 0, ry = 0.5, rz = 0, rw = 0.8660254, fov = 75 },
		{ t = 1, x = 200, y = -180, z = 181.5, rx = 0, ry = 0.7071, rz = 0, rw = 0.7071, fov = 60 },
	}
	local path: CameraPath = { sampleHz = 30, keys = keys, offset = 0.25 }

	local shot = ShotFile.capture("Final Round", comp, layers, path)
	local text = ShotFile.encode(shot, json)
	Harness.check(#text > 0, "encoding produces text")

	local restored, problem = ShotFile.decode(text, json)
	Harness.isNil(problem, "and it decodes without complaint")
	Harness.notNil(restored, "yielding a shot")

	if restored ~= nil then
		local back = restored :: Shot
		Harness.equal(back.version, shot.version, "the version survives")
		Harness.equal(back.name, "Final Round", "the name survives")
		Harness.equal(back.alignMode, "wallclock", "the align mode survives")
		Harness.near(back.speed, 0.5, "the speed survives")
		Harness.near(back.rangeStart, 2, "the range survives")
		Harness.near(back.rangeEnd, 30, "to its end")
		Harness.equal(#back.layers, 1, "the layer count survives")
		Harness.equal(back.layers[1].file, "final.a2replay", "layer files are stored as names")
		Harness.equal(back.layers[1].label, "Final", "with their labels")
		Harness.near(back.layers[1].offset, -2.5, "and their offsets")

		Harness.notNil(back.path, "the path survives")
		if back.path ~= nil then
			local was = back.path :: CameraPath
			Harness.near(was.sampleHz, 30, "at the same rate")
			Harness.near(was.offset, 0.25, "and offset")
			Harness.equal(#was.keys, 3, "with every keyframe")
			Harness.near(was.keys[2].x, 150.125, "positions come back exactly", 1e-9)
			Harness.near(was.keys[2].y, -200, "including negatives")
			Harness.near(was.keys[2].z, 180.75, "and fractions", 1e-9)
			Harness.near(was.keys[3].rw, 0.7071, "quaternion components too", 1e-9)
			Harness.near(was.keys[3].fov, 60, "and the field of view")
		end
	end
end

---- Reading files that are not quite right -----------------------------------

local function decodeText(text: string): (Shot?, string?)
	return ShotFile.decode(text, json)
end

do
	local shot, problem = decodeText("")
	Harness.isNil(shot, "an empty file is refused")
	Harness.check(problem ~= nil and string.find(problem :: string, "empty", 1, true) ~= nil, "saying so plainly")
end

do
	local shot, problem = decodeText("this is not json at all")
	Harness.isNil(shot, "garbage is refused rather than throwing")
	Harness.notNil(problem, "with a reason")
end

do
	local shot, problem = decodeText("42")
	Harness.isNil(shot, "valid json that is not an object is refused")
	Harness.check(problem ~= nil and string.find(problem :: string, "shot object", 1, true) ~= nil, "naming the problem")

	shot, problem = decodeText("[1, 2, 3]")
	Harness.isNil(shot, "and an array is refused too")
	Harness.check(problem ~= nil and string.find(problem :: string, "version", 1, true) ~= nil, "with a usable reason")
end

do
	local shot, problem = decodeText('{"layers":[{"file":"a"}]}')
	Harness.isNil(shot, "a file with no version is refused")
	Harness.check(problem ~= nil and string.find(problem :: string, "version", 1, true) ~= nil, "and says why")
end

do
	local shot, problem = decodeText('{"version":99,"layers":[{"file":"a"}]}')
	Harness.isNil(shot, "a file from a newer version is refused")
	Harness.check(
		problem ~= nil and string.find(problem :: string, "newer", 1, true) ~= nil,
		"rather than misreading fields it does not know"
	)
end

do
	local shot, problem = decodeText('{"version":1,"layers":[]}')
	Harness.isNil(shot, "an empty shot has nothing to restore")
	Harness.notNil(problem, "and says so")
end

do
	-- A path alone is a useful shot: a camera move with no replays attached is still
	-- worth reloading.
	local shot, problem = decodeText(
		'{"version":1,"name":"move only","layers":[],"path":{"sampleHz":30,"offset":0,"keys":[{"t":0,"x":1,"y":2,"z":3,"rx":0,"ry":0,"rz":0,"rw":1,"fov":90}]}}')
	Harness.isNil(problem, "a path-only shot loads")
	if shot ~= nil then
		Harness.equal(#(shot :: Shot).layers, 0, "with no layers")
		Harness.notNil((shot :: Shot).path, "and a path")
	end
end

---- Repairing what a person may have edited ----------------------------------

do
	local shot, _problem = decodeText(
		[[{"version":1,"name":"edited","syncMode":"telepathy","loopMode":"sideways","speed":1000,
		   "layers":[{"file":"C:\\replays\\Match.A2Replay","offset":9e9},
				     {"file":"second","overflow":"loop"},
				     {"label":"no file here"},
				     "junk"],
		   "path":{"sampleHz":0,"keys":[
				{"t":2,"x":0,"y":0,"z":0,"rx":0,"ry":0,"rz":0,"rw":1},
				{"t":1,"x":1,"y":1,"z":1,"rx":0,"ry":0,"rz":0,"rw":1,"fov":90},
				{"t":3,"x":null,"y":0,"z":0,"rx":0,"ry":0,"rz":0,"rw":1,"fov":90},
				{"t":4}
			]}}]])
	Harness.notNil(shot, "a hand-edited file still loads where it can")
	if shot ~= nil then
		local back = shot :: Shot
		Harness.equal(back.syncMode, "masterClock", "an unknown sync mode falls back")
		Harness.equal(back.loopMode, "loop", "as does an unknown loop mode")
		Harness.near(back.speed, 16, "an impossible speed is clamped, not obeyed")
		Harness.equal(#back.layers, 2, "entries without a file name are dropped")
		Harness.equal(back.layers[1].file, "Match.A2Replay", "a layer file is reduced to its name")
		Harness.equal(back.layers[1].label, "Match", "and gets a label derived from it")
		Harness.near(back.layers[1].offset, 86400, "a wild offset is clamped to a day either way")
		Harness.equal(back.layers[2].overflow, "loop", "a valid overflow is kept")

		Harness.notNil(back.path, "the path loads")
		if back.path ~= nil then
			local was = back.path :: CameraPath
			Harness.near(was.sampleHz, 30, "an unusable sample rate falls back")
			Harness.equal(#was.keys, 2, "keyframes with missing or broken numbers are dropped")
			Harness.near(was.keys[1].t, 1, "and the survivors are sorted by time, which playback assumes")
			Harness.near(was.keys[2].t, 2, "in the right order")
			Harness.near(was.keys[2].fov, 90, "a key with no field of view gets the default")
		end
	end
end

---- Applying a decoded shot --------------------------------------------------

do
	local shot, _ = decodeText(
		'{"version":1,"syncMode":"independent","alignMode":"wallclock","loopMode":"stop","speed":0.25,"rangeStart":5,"rangeEnd":12,"layers":[{"file":"a","offset":1.5,"overflow":"loop"}]}')
	Harness.notNil(shot, "the fixture decodes")
	if shot ~= nil then
		local comp = Layers.newComposition()
		comp.playing = true
		comp.masterT = 44
		ShotFile.applyComposition(shot :: Shot, comp)
		Harness.equal(comp.syncMode, "independent", "the timing modes are applied")
		Harness.equal(comp.alignMode, "wallclock", "all of them")
		Harness.equal(comp.loopMode, "stop", "including loop behaviour")
		Harness.near(comp.speed, 0.25, "and the speed")
		Harness.near(comp.rangeStart, 5, "and the range")
		Harness.near(comp.rangeEnd, 12, "end to end")
		Harness.near(comp.masterT, 0, "the clock restarts rather than jumping to a stale time")
		Harness.equal(comp.playing, false, "and stays paused until asked")

		local built: { Layer } = ShotFile.buildLayers(shot :: Shot)
		Harness.equal(#built, 1, "layers are rebuilt from the shot")
		Harness.equal(built[1].file, "a", "under their stored name")
		Harness.near(built[1].offset, 1.5, "keeping their offsets")
		Harness.equal(built[1].overflow, "loop", "and their overflow rule")
		Harness.equal(built[1].missing, true, "marked missing until a handle resolves")
		Harness.isNil(built[1].handle, "with no handle bound yet")
	end
end

do
	-- A zero-length range means "use whatever the layers give", so it must not be
	-- written onto a composition that already has a real window.
	local shot, _ = decodeText('{"version":1,"layers":[{"file":"a"}],"rangeStart":0,"rangeEnd":0}')
	if shot ~= nil then
		local comp = Layers.newComposition()
		comp.rangeStart = 3
		comp.rangeEnd = 7
		ShotFile.applyComposition(shot :: Shot, comp)
		Harness.near(comp.rangeStart, 0, "a degenerate range resets the window to the natural one")
		Harness.near(comp.rangeEnd, 0, "rather than leaving a stale span behind")
	end
end

local failures = Harness.report()
if failures > 0 then
	error(string.format("%d shotfile checks failed", failures), 0)
end
