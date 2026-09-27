--!strict
--[[
	Vector helpers.

	The spectator API's own vectors do support `+`, `-` and `*` through metatable
	metamethods, but those operators are invisible to a strict type check written
	against a definition file, so arithmetic is done explicitly here. It also
	keeps every operation in this codebase checkable rather than "works at
	runtime, red in the editor".

	Axis convention, matching the game: +X forward, +Y right, +Z up. Units cm.
]]

local Types = require("types")
type Vec3Struct = Types.Vec3Struct
type QuatStruct = Types.QuatStruct
type PathKey = Types.PathKey

local VecMath = {}

-- The API constructor is injected where an engine vector is required, so the
-- pure maths below can be exercised by the tests without the client running.
export type VecFactory = (x: number, y: number, z: number) -> Vec3Struct

function VecMath.newVec(x: number, y: number, z: number): Vec3Struct
	return { x = x, y = y, z = z }
end

---- Plain-number maths ---------------------------------------------------------

function VecMath.length(x: number, y: number, z: number): number
	return math.sqrt(x * x + y * y + z * z)
end

-- Returns a unit vector, or the fallback when the input is too short to
-- normalise. Never returns a NaN vector, which is what makes it safe for gravity
-- directions that can legitimately be zero-length in zero-g zones.
function VecMath.normalizeOr(
	x: number,
	y: number,
	z: number,
	fallbackX: number,
	fallbackY: number,
	fallbackZ: number
): (number, number, number)
	local length = VecMath.length(x, y, z)
	if length < 1e-6 then
		return fallbackX, fallbackY, fallbackZ
	end
	return x / length, y / length, z / length
end

function VecMath.dot(ax: number, ay: number, az: number, bx: number, by: number, bz: number): number
	return ax * bx + ay * by + az * bz
end

function VecMath.cross(ax: number, ay: number, az: number, bx: number, by: number, bz: number): (number, number, number)
	return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

function VecMath.distance(a: Vec3Struct, b: Vec3Struct): number
	return VecMath.length(a.x - b.x, a.y - b.y, a.z - b.z)
end

---- Movement basis from yaw / pitch -------------------------------------------
-- Yaw is measured from +X towards +Y, pitch is up-positive, both in degrees.
-- Returning the axes as plain numbers keeps the integrator a pure function.

function VecMath.basisFromAngles(yawDegrees: number, pitchDegrees: number): (Vec3Struct, Vec3Struct, Vec3Struct)
	local yaw = math.rad(yawDegrees)
	local pitch = math.rad(pitchDegrees)
	local cosPitch = math.cos(pitch)

	local fx = cosPitch * math.cos(yaw)
	local fy = cosPitch * math.sin(yaw)
	local fz = math.sin(pitch)

	-- Horizontal, 90 degrees clockwise from forward when viewed from +Z.
	local rx = -math.sin(yaw)
	local ry = math.cos(yaw)

	-- Up completes the frame. The operand order matters: forward x right is +Z at
	-- the identity pose, whereas right x forward is -Z, which would hand lookAt an
	-- upside-down up vector and invert the vertical controls. The analytic fallback
	-- below is the same vector derived by differentiating forward with respect to
	-- pitch, and it is the check that pins this sign down.
	local ux, uy, uz = VecMath.cross(fx, fy, fz, rx, ry, 0)
	ux, uy, uz = VecMath.normalizeOr(
		ux,
		uy,
		uz,
		-math.sin(pitch) * math.cos(yaw),
		-math.sin(pitch) * math.sin(yaw),
		math.cos(pitch)
	)

	return { x = fx, y = fy, z = fz }, { x = rx, y = ry, z = 0 }, { x = ux, y = uy, z = uz }
end

-- Keeps pitch clear of the poles so lookAt cannot flip.
function VecMath.clampPitch(pitchDegrees: number): number
	local limit = 89.5
	if pitchDegrees > limit then
		return limit
	elseif pitchDegrees < -limit then
		return -limit
	end
	return pitchDegrees
end

-- Wraps an angle into (-180, 180] so yaw cannot wander into huge values over a
-- long session, which would eventually cost precision in the trig calls.
function VecMath.wrapAngle(degrees: number): number
	local wrapped = degrees % 360
	if wrapped > 180 then
		wrapped -= 360
	elseif wrapped <= -180 then
		wrapped += 360
	end
	return wrapped
end

---- Quaternion maths for the recorded camera path ------------------------------

-- Raw dot product of two quaternions. Its absolute value is the cosine of the
-- angle between the two orientations, so `math.abs(dot) < 0.9999` is a cheap
-- "the camera turned" test that does not need any trig.
function VecMath.quatDot(
	ax: number,
	ay: number,
	az: number,
	aw: number,
	bx: number,
	by: number,
	bz: number,
	bw: number
): number
	return ax * bx + ay * by + az * bz + aw * bw
end

-- Spherical interpolation between two quaternions. Falls back to a normalised
-- linear blend when the poses are nearly identical, which is the usual case for
-- keys sampled at 30 Hz. Negates the target when the dot product is negative so
-- the interpolation takes the short way round.
function VecMath.slerpQuat(
	ax: number,
	ay: number,
	az: number,
	aw: number,
	bx: number,
	by: number,
	bz: number,
	bw: number,
	t: number
): (number, number, number, number)
	local dot = ax * bx + ay * by + az * bz + aw * bw
	local sx, sy, sz, sw = bx, by, bz, bw
	if dot < 0 then
		dot = -dot
		sx, sy, sz, sw = -bx, -by, -bz, -bw
	end

	if dot > 0.9995 then
		local rx = ax + (sx - ax) * t
		local ry = ay + (sy - ay) * t
		local rz = az + (sz - az) * t
		local rw = aw + (sw - aw) * t
		local length = math.sqrt(rx * rx + ry * ry + rz * rz + rw * rw)
		if length < 1e-9 then
			return ax, ay, az, aw
		end
		return rx / length, ry / length, rz / length, rw / length
	end

	local theta = math.acos(if dot > 1 then 1 else dot)
	local sinTheta = math.sin(theta)
	local wa = math.sin((1 - t) * theta) / sinTheta
	local wb = math.sin(t * theta) / sinTheta
	return ax * wa + sx * wb, ay * wa + sy * wb, az * wa + sz * wb, aw * wa + sw * wb
end

-- Returns the key index pair that brackets `time` plus the blend factor between
-- them. Assumes keys are sorted by t, which the recorder guarantees.
--
-- Typed against PathKey rather than `{ { t: number } }`: Luau checks array
-- element types invariantly, so a loose `{ t: number }` parameter rejects
-- `{ PathKey }` for having extra fields. (A `<Key: { t: number }>` generic would
-- express it properly, but this Luau parser does not accept constrained
-- generics.)
function VecMath.bracketTimes(keys: { PathKey }, time: number): (number, number, number)
	local count = #keys
	if count == 0 then
		return 0, 0, 0
	elseif count == 1 then
		return 1, 1, 0
	elseif time <= keys[1].t then
		return 1, 1, 0
	elseif time >= keys[count].t then
		return count, count, 0
	end

	-- Linear walk from the end of the previous lookup is faster in practice, but
	-- a plain search keeps this function stateless and therefore testable.
	local low = 1
	local high = count
	while high - low > 1 do
		local middle = math.floor((low + high) / 2)
		if keys[middle].t <= time then
			low = middle
		else
			high = middle
		end
	end

	local span = keys[high].t - keys[low].t
	local factor = if span > 0 then (time - keys[low].t) / span else 0
	return low, high, factor
end

return VecMath
