--!strict
--[[
	Tests for camera path capture and playback.

	The recording rules are the interesting part: sample on a timer alone and a parked
	camera writes hundreds of identical keyframes; sample only on change and a slow
	linear dolly produces a polyline with visible corners. Both rules and the stillness
	fallback are asserted here, because it is the one piece of the package where the
	symptom (a stutter at one point in the shot) is far from the cause.
]]

local Harness = require("./harness")
local Path = require("../pkg/camerapath")
local Types = require("../pkg/types")

type Recorder = Path.Recorder
type PathKey = Types.PathKey
type CameraPath = Types.CameraPath

Harness.suite("camerapath")

local function record(recorder: Recorder, time: number, x: number, fov: number?): boolean
	local z = x
	return Path.maybeRecord(recorder, time, x, 0, z, 0, 0, 0, 1, fov or 90)
end

local function pathOf(keys: { PathKey }, sampleHz: number?): CameraPath
	return { sampleHz = sampleHz or 30, keys = keys, offset = 0 }
end

---- Recorder setup -----------------------------------------------------------

do
	local recorder = Path.newRecorder(30, 100)
	Harness.near(recorder.sampleHz, 30, "the sample rate is kept")
	Harness.near(recorder.interval, 1 / 30, "and becomes the key interval")
	Harness.equal(recorder.maxKeys, 100, "the key budget is kept")
	Harness.equal(#recorder.keys, 0, "starting empty")
end

do
	-- A zero or negative rate would divide by zero when the interval is derived.
	local recorder = Path.newRecorder(0, 1)
	Harness.near(recorder.sampleHz, 30, "an unusable rate falls back to the default")
	Harness.near(recorder.interval, 1 / 30, "with a usable interval")
	Harness.equal(recorder.maxKeys, 2, "and the key budget never goes below two")
end

---- What gets a keyframe -----------------------------------------------------

do
	local recorder = Path.newRecorder(30, 100)
	Harness.equal(record(recorder, 0, 0), true, "the first frame always records")
	Harness.equal(#recorder.keys, 1, "one key stored")
	Harness.near(recorder.keys[1].t, 0, "stamped with the clock time")

	Harness.equal(record(recorder, 0, 500), false, "a repeated timestamp is refused even while moving")
	Harness.equal(record(recorder, 0.01, 900), false, "and anything closer than the interval is skipped")
	Harness.equal(#recorder.keys, 1, "so nothing was added")
	Harness.equal(record(recorder, 0.05, 900), true, "once the interval has passed, movement records")
	Harness.equal(#recorder.keys, 2, "as one key")
end

do
	local recorder = Path.newRecorder(30, 100)
	record(recorder, 0, 0)
	-- A parked camera: past the interval but with nothing moved.
	Harness.equal(record(recorder, 0.05, 0), false, "a still camera does not record")
	-- The stillness fallback: after a full second of nothing, one anchoring key.
	Harness.equal(record(recorder, 1.5, 0), true, "but a held still shot gets an anchor key")
	Harness.equal(#recorder.keys, 2, "exactly one more")
end

do
	local recorder = Path.newRecorder(30, 100)
	record(recorder, 0, 0)
	Harness.equal(record(recorder, 0.05, 0.5), false, "half a centimetre of drift is not movement")
	local turned = Path.maybeRecord(recorder, 0.1, 0, 0, 0, 0, 0, math.sin(math.rad(20)), math.cos(math.rad(20)), 90)
	Harness.equal(turned, true, "a 40 degree turn is")
	-- Same orientation as the previous key, so the only thing that changed is the
	-- zoom: this asserts the field-of-view rule on its own rather than riding along
	-- on a rotation that would have recorded anyway.
	local zoomed = Path.maybeRecord(
		recorder,
		0.2,
		0,
		0,
		0,
		0,
		0,
		math.sin(math.rad(20)),
		math.cos(math.rad(20)),
		80
	)
	Harness.equal(zoomed, true, "and so is a field-of-view change")
end

do
	-- Out-of-order time is the scrub case. bracketTimes assumes the key list is
	-- sorted, so appending a past timestamp would corrupt playback.
	local recorder = Path.newRecorder(30, 100)
	record(recorder, 5, 0)
	Harness.equal(record(recorder, 5, 100), false, "the same timestamp twice is refused")
	Harness.equal(record(recorder, 4, 100), false, "and a step backwards is refused")
	Harness.equal(#recorder.keys, 1, "the path stays sorted")
end

do
	local recorder = Path.newRecorder(30, 100)
	Harness.equal(record(recorder, 0 / 0, 0), false, "a NaN clock time is refused")
	Harness.equal(#recorder.keys, 0, "and poisons nothing")
end

do
	-- The budget has to stop cleanly rather than grow without limit: a long session
	-- at 30 Hz is 108 000 keys an hour.
	local recorder = Path.newRecorder(30, 3)
	for index = 0, 10 do
		record(recorder, index * 0.2, index * 100)
	end
	Harness.equal(#recorder.keys, 3, "the key budget is a hard stop")
	Harness.equal(recorder.truncated, true, "and says so")
	Harness.check(Path.duration(recorder) > 0, "duration reports the last key time")
end

do
	local recorder = Path.newRecorder(30, 100)
	record(recorder, 1, 0)
	record(recorder, 4, 500)
	Harness.near(Path.duration(recorder), 4, "duration is the span to the last key")
	Path.reset(recorder)
	Harness.equal(#recorder.keys, 0, "reset clears the keys")
	Harness.equal(recorder.truncated, false, "and the truncation flag")
	Harness.near(Path.duration(recorder), 0, "and the duration")
	Harness.equal(record(recorder, 0, 0), true, "and recording resumes from any time")
end

---- Playback -----------------------------------------------------------------

do
	local empty: { PathKey } = {}
	Harness.isNil(Path.sampleAt(pathOf(empty), 1), "an empty path samples to nil")
	Harness.equal(Path.keyCount(pathOf(empty)), 0, "and reports no keys")
end

do
	local keys: { PathKey } = {
		{ t = 0, x = 0, y = 0, z = 100, rx = 0, ry = 0, rz = 0, rw = 1, fov = 90 },
		{ t = 2, x = 200, y = 0, z = 100, rx = 0, ry = 0, rz = 0, rw = 1, fov = 70 },
	}
	local path = pathOf(keys)

	local start = Path.sampleAt(path, 0)
	Harness.notNil(start, "the first key samples")
	if start ~= nil then
		Harness.near(start.x, 0, "at its own position")
		Harness.near(start.fov, 90, "and its own field of view")
	end

	local mid = Path.sampleAt(path, 1)
	Harness.notNil(mid, "the midpoint samples")
	if mid ~= nil then
		Harness.near(mid.x, 100, "position interpolates linearly")
		Harness.near(mid.fov, 80, "and so does the field of view")
	end

	local late = Path.sampleAt(path, 99)
	if late ~= nil then
		Harness.near(late.x, 200, "past the end it holds the last key")
		Harness.near(late.fov, 70, "instead of running off")
	else
		Harness.check(false, "past the end should still sample")
	end

	local early = Path.sampleAt(path, -5)
	if early ~= nil then
		Harness.near(early.x, 0, "before the start it holds the first key")
	else
		Harness.check(false, "before the start should still sample")
	end
end

do
	-- Rotation must slerp, not lerp the components: lerping quaternion components
	-- between two orientations shortens the vector and makes the camera shrink-turn
	-- through the middle of a move.
	local half = math.sin(math.rad(45))
	local keys: { PathKey } = {
		{ t = 0, x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, rw = 1, fov = 90 },
		{ t = 1, x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = half, rw = half, fov = 90 },
	}
	local mid = Path.sampleAt(pathOf(keys), 0.5)
	Harness.notNil(mid, "a rotating path samples")
	if mid ~= nil then
		local magnitude = math.sqrt(mid.rx ^ 2 + mid.ry ^ 2 + mid.rz ^ 2 + mid.rw ^ 2)
		Harness.near(magnitude, 1, "the sampled quaternion is still unit length", 1e-6)
		Harness.near(math.abs(mid.rw), math.cos(math.rad(22.5)), "halfway is a 45 degree turn", 1e-6)
	end
end

do
	-- The path's own offset is what lets a shot play against a replay that started
	-- later; sampleAt takes the caller's time, so the offset has to be applied by
	-- the caller. This pins down which side owns it.
	local keys: { PathKey } = {
		{ t = 10, x = 100, y = 0, z = 0, rx = 0, ry = 0, rz = 0, rw = 1, fov = 90 },
	}
	local shifted = Path.sampleAt({ sampleHz = 30, keys = keys, offset = 10 }, 0)
	Harness.notNil(shifted, "sampling at 0 against a path that starts at 10 still yields a pose")
	if shifted ~= nil then
		Harness.near(shifted.x, 100, "and it is the first key, held rather than invented")
	end
end

---- Remaining ----------------------------------------------------------------

do
	local keys: { PathKey } = {
		{ t = 1, x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, rw = 1, fov = 90 },
		{ t = 5, x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, rw = 1, fov = 90 },
	}
	local path = pathOf(keys)
	Harness.near(Path.remaining(path, 3), -2, "inside the path the remaining time is negative")
	Harness.near(Path.remaining(path, 7), 2, "past the end it is positive, which is what the notice reads")
	Harness.near(Path.remaining(pathOf({}), 7), 0, "an empty path reports no overrun")
end

local failures = Harness.report()
if failures > 0 then
	error(string.format("%d camerapath checks failed", failures), 0)
end
