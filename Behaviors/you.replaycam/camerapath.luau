--!strict
--[[
	Recorded camera path.

	Two jobs, both pure functions of plain numbers:

	* **Record** a flying shot as keyframes sampled against whatever clock the
	  caller supplies, so the shot can be re-flown later. The caller passes the
	  composition clock rather than wall time, which is what keeps a recorded shot
	  locked to the replays it was filmed against.
	* **Play** those keyframes back at any time value, interpolating position,
	  rotation and field of view.

	The keyframe record is written out by shotfile into the shot JSON, which is
	what makes a shot portable and reusable rather than session-only.
]]

local Types = require("types")
local VecMath = require("vecmath")

type PathKey = Types.PathKey
type CameraPath = Types.CameraPath

export type Recorder = {
	sampleHz: number,
	maxKeys: number,
	interval: number,
	lastKeyTime: number,
	keys: { PathKey },
	truncated: boolean,
	sampleCount: number,
}

-- A pose read back from the path.
export type SampledPose = {
	x: number,
	y: number,
	z: number,
	rx: number,
	ry: number,
	rz: number,
	rw: number,
	fov: number,
}

local Path = {}

local DEFAULT_SAMPLE_HZ = 30

function Path.newRecorder(sampleHz: number, maxKeys: number): Recorder
	local hz = if sampleHz > 0 then sampleHz else DEFAULT_SAMPLE_HZ
	return {
		sampleHz = hz,
		maxKeys = if maxKeys > 1 then maxKeys else 2,
		interval = 1 / hz,
		lastKeyTime = -math.huge,
		keys = {},
		truncated = false,
		sampleCount = 0,
	}
end

function Path.reset(recorder: Recorder)
	recorder.keys = {}
	recorder.lastKeyTime = -math.huge
	recorder.truncated = false
	recorder.sampleCount = 0
end

function Path.duration(recorder: Recorder): number
	local keys = recorder.keys
	if #keys == 0 then
		return 0
	end
	return keys[#keys].t
end

--[[
	Records a keyframe if enough time has passed and the pose actually changed.

	Both checks matter. Sampling on time alone produces a key every 33 ms even
	while the camera is parked, which bloats the shot file with hundreds of
	identical keys; sampling only on change produces nothing at all during a slow
	linear dolly, which turns the path into a polyline with visible direction
	corners. Requiring "enough time passed AND something moved", with a hard
	fallback interval, gets both cases right.
]]
function Path.maybeRecord(
	recorder: Recorder,
	time: number,
	x: number,
	y: number,
	z: number,
	rx: number,
	ry: number,
	rz: number,
	rw: number,
	fov: number
): boolean
	if not (time == time) then -- NaN guard: a bad smoothed value must not poison the shot
		return false
	end

	local keys = recorder.keys
	local last = keys[#keys]

	if last ~= nil and time <= last.t then
		-- The clock went backwards (scrub, loop, or a rewound composition). Do not
		-- append out-of-order keys; bracketTimes assumes the list is sorted.
		return false
	end

	if #keys >= recorder.maxKeys then
		recorder.truncated = true
		return false
	end

	if time - recorder.lastKeyTime < recorder.interval then
		return false
	end

	if last ~= nil then
		local moved = VecMath.length(x - last.x, y - last.y, z - last.z)
		local turned = math.abs(VecMath.quatDot(last.rx, last.ry, last.rz, last.rw, rx, ry, rz, rw))
		local fovChanged = math.abs(fov - last.fov) > 0.01
		local turnedEnough = turned < 0.9999
		-- Force a key after a full second of stillness so a held shot still has a
		-- keyframe anchoring that span.
		if not (moved > 1 or turnedEnough or fovChanged) and time - last.t < 1 then
			recorder.lastKeyTime = time
			return false
		end
	end

	table.insert(keys, { t = time, x = x, y = y, z = z, rx = rx, ry = ry, rz = rz, rw = rw, fov = fov })
	recorder.lastKeyTime = time
	recorder.sampleCount += 1
	return true
end

-- Reads the pose at `time`, interpolating between the bracketing keys.
-- Returns nil for an empty path so the caller can leave the camera alone.
function Path.sampleAt(path: CameraPath, time: number): SampledPose?
	local keys = path.keys
	if keys == nil or #keys == 0 then
		return nil
	end

	local low, high, factor = VecMath.bracketTimes(keys, time)
	if low == 0 then
		return nil
	end

	local a = keys[low]
	local b = keys[high]

	if a == b or factor <= 0 then
		return { x = a.x, y = a.y, z = a.z, rx = a.rx, ry = a.ry, rz = a.rz, rw = a.rw, fov = a.fov }
	end

	local rx, ry, rz, rw = VecMath.slerpQuat(a.rx, a.ry, a.rz, a.rw, b.rx, b.ry, b.rz, b.rw, factor)
	return {
		x = a.x + (b.x - a.x) * factor,
		y = a.y + (b.y - a.y) * factor,
		z = a.z + (b.z - a.z) * factor,
		rx = rx,
		ry = ry,
		rz = rz,
		rw = rw,
		fov = a.fov + (b.fov - a.fov) * factor,
	}
end

-- How far past the end of the path a time value is, for the "path finished"
-- notice. Negative while still inside the path.
function Path.remaining(path: CameraPath, time: number): number
	local keys = path.keys
	if keys == nil or #keys == 0 then
		return 0
	end
	return (keys[#keys].t - time) * -1
end

function Path.keyCount(path: CameraPath): number
	return if path.keys then #path.keys else 0
end

return Path
