--!strict
--[[
	Tests for the maths that decides where the camera points and how a captured
	path is read back.

	These matter because the failure modes are invisible in isolation: a yaw of 190
	degress reported as 190 instead of -170 only shows up as the camera snapping
	round, and a bracket lookup that returns the wrong pair only shows up as a
	stutter at one keyframe.
]]

local Harness = require("./harness")
local VecMath = require("../pkg/vecmath")
local Types = require("../pkg/types")

type PathKey = Types.PathKey

Harness.suite("vecmath")

local function key(t: number, x: number): PathKey
	return { t = t, x = x, y = 0, z = 0, rx = 0, ry = 0, rz = 0, rw = 1, fov = 90 }
end

---- Basis --------------------------------------------------------------------

do
	local forward, right, up = VecMath.basisFromAngles(0, 0)
	Harness.near(forward.x, 1, "yaw 0 pitch 0 looks along +X", 1e-9)
	Harness.near(forward.y, 0, "yaw 0 has no +Y component", 1e-9)
	Harness.near(forward.z, 0, "yaw 0 is level", 1e-9)
	Harness.near(right.y, 1, "right is +Y at yaw 0", 1e-9)
	Harness.near(up.z, 1, "up is +Z at yaw 0", 1e-9)
end

do
	-- A quarter turn: the arena's forward is +X, so 90 degrees is +Y.
	local forward, right = VecMath.basisFromAngles(90, 0)
	Harness.near(forward.y, 1, "yaw 90 looks along +Y", 1e-9)
	Harness.near(forward.x, 0, "yaw 90 has lost its +X component", 1e-9)
	Harness.near(right.x, -1, "right of yaw 90 is -X", 1e-9)
end

do
	-- Pitch straight up is the pole where the up vector has to be derived rather
	-- than read off, so it is the case most likely to come out as NaN.
	local forward, _, up = VecMath.basisFromAngles(0, 90)
	Harness.near(forward.z, 1, "pitch 90 looks along +Z", 1e-6)
	Harness.check(VecMath.length(up.x, up.y, up.z) > 0.9, "up is still a real vector at the pole")
	Harness.check(up.x == up.x and up.y == up.y and up.z == up.z, "up is not NaN at the pole")
end

do
	-- Orthonormal at an arbitrary angle, which is what keeps strafing at a constant
	-- speed no matter where the camera is pointing.
	local forward, right, up = VecMath.basisFromAngles(37.5, -22.25)
	Harness.near(VecMath.length(forward.x, forward.y, forward.z), 1, "forward is unit length", 1e-9)
	Harness.near(VecMath.length(right.x, right.y, right.z), 1, "right is unit length", 1e-9)
	Harness.near(VecMath.length(up.x, up.y, up.z), 1, "up is unit length", 1e-9)
	Harness.near(VecMath.dot(forward.x, forward.y, forward.z, right.x, right.y, right.z), 0, "forward ⟂ right", 1e-9)
	Harness.near(VecMath.dot(forward.x, forward.y, forward.z, up.x, up.y, up.z), 0, "forward ⟂ up", 1e-9)
	Harness.near(VecMath.dot(right.x, right.y, right.z, up.x, up.y, up.z), 0, "right ⟂ up", 1e-9)
end

---- Pitch and angle wrapping --------------------------------------------------

Harness.near(VecMath.clampPitch(45), 45, "a sane pitch passes through")
Harness.near(VecMath.clampPitch(500), 89.5, "pitch is clamped below the pole")
Harness.near(VecMath.clampPitch(-500), -89.5, "pitch is clamped above the lower pole")

Harness.near(VecMath.wrapAngle(0), 0, "zero wraps to zero")
Harness.near(VecMath.wrapAngle(180), 180, "180 stays at the wrap boundary")
Harness.near(VecMath.wrapAngle(190), -170, "190 wraps to -170")
Harness.near(VecMath.wrapAngle(-190), 170, "-190 wraps to 170")
Harness.near(VecMath.wrapAngle(720), 0, "two full turns wrap to zero")
Harness.near(VecMath.wrapAngle(361), 1, "just past a full turn")

---- Vector helpers ------------------------------------------------------------

Harness.near(VecMath.length(3, 4, 0), 5, "3-4-5 triangle")
Harness.near(VecMath.length(0, 0, 0), 0, "the zero vector has no length")

do
	local x, y, z = VecMath.normalizeOr(0, 0, 0, 1, 2, 3)
	Harness.near(x, 1, "normalising zero falls back to the given vector")
	Harness.near(y, 2, "fallback keeps Y")
	Harness.near(z, 3, "fallback keeps Z")
	local nx, _ny, nz = VecMath.normalizeOr(0, 0, -10, 1, 0, 0)
	Harness.near(nz, -1, "a non-zero vector is normalised, not replaced")
	Harness.near(nx, 0, "normalising keeps the direction pure")
end

Harness.near(VecMath.dot(1, 0, 0, 0, 1, 0), 0, "perpendicular dot is zero")
Harness.near(VecMath.dot(2, 0, 0, 3, 0, 0), 6, "parallel dot multiplies")

do
	local x, _y, z = VecMath.cross(1, 0, 0, 0, 1, 0)
	Harness.near(z, 1, "X cross Y is +Z")
	Harness.near(x, 0, "X cross Y has no X")
end

Harness.near(VecMath.distance({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 100 }), 100, "distance in cm")

---- Quaternions ---------------------------------------------------------------

Harness.near(math.abs(VecMath.quatDot(0, 0, 0, 1, 0, 0, 0, 1)), 1, "a quaternion matches itself")
Harness.near(math.abs(VecMath.quatDot(0, 0, 0, 1, 1, 0, 0, 0)), 0, "perpendicular quaternions are 90 degrees apart")

do
	-- Identity to a quarter turn about Z, sampled at both ends and in the middle.
	local ax, ay, az, aw = 0, 0, 0, 1
	local half = math.sin(math.rad(45))
	local bx, by, bz, bw = 0, 0, half, math.cos(math.rad(45))

	local sx, sy, sz, sw = VecMath.slerpQuat(ax, ay, az, aw, bx, by, bz, bw, 0)
	Harness.near(math.abs(sw), 1, "slerp at 0 is the first quaternion")
	Harness.check(VecMath.quatDot(sx, sy, sz, sw, ax, ay, az, aw) > 0.9999, "slerp at 0 lands on a")

	local ex, ey, ez, ew = VecMath.slerpQuat(ax, ay, az, aw, bx, by, bz, bw, 1)
	Harness.check(VecMath.quatDot(ex, ey, ez, ew, bx, by, bz, bw) > 0.9999, "slerp at 1 lands on b")

	local mx, my, mz, mw = VecMath.slerpQuat(ax, ay, az, aw, bx, by, bz, bw, 0.5)
	local toA = VecMath.quatDot(mx, my, mz, mw, ax, ay, az, aw)
	local toB = VecMath.quatDot(mx, my, mz, mw, bx, by, bz, bw)
	Harness.check(toA > 0.9, "the midpoint is close to the start")
	Harness.near(toA, toB, "the midpoint is equidistant from both ends", 1e-6)
end

do
	-- Negating a quaternion is the same rotation, so the interpolation must take the
	-- short way round instead of spinning through the long arc.
	local ax, ay, az, aw = 0, 0, 0, 1
	local _mx, _my, _mz, mw = VecMath.slerpQuat(ax, ay, az, aw, 0, 0, 0, -1, 0.5)
	Harness.check(math.abs(mw) > 0.9999, "slerp to the negated identity stays put")
end

---- Key lookup ----------------------------------------------------------------

do
	local empty: { PathKey } = {}
	local low, high, factor = VecMath.bracketTimes(empty, 5)
	Harness.equal(low, 0, "no keys means no bracket")
	Harness.equal(high, 0, "no upper index either")
	Harness.near(factor, 0, "no interpolation weight")
end

do
	local one: { PathKey } = { key(2, 10) }
	local low, high, factor = VecMath.bracketTimes(one, 99)
	Harness.equal(low, 1, "a single key brackets itself")
	Harness.equal(high, 1, "and is its own upper bound")
	Harness.near(factor, 0, "with no span to interpolate over")
end

do
	local keys: { PathKey } = { key(0, 0), key(1, 10), key(2, 20), key(4, 40) }
	local low, high, factor = VecMath.bracketTimes(keys, 0)
	Harness.equal(low, 1, "exactly the first key")
	Harness.equal(high, 1, "clamps at the start")

	low, high, factor = VecMath.bracketTimes(keys, -5)
	Harness.equal(low, 1, "before the first key clamps to it")
	Harness.near(factor, 0, "and does not extrapolate backwards")

	low, high, factor = VecMath.bracketTimes(keys, 100)
	Harness.equal(low, 4, "past the last key clamps to it")
	Harness.equal(high, 4, "and holds there")
	Harness.near(factor, 0, "and does not extrapolate forwards")

	low, high, factor = VecMath.bracketTimes(keys, 1)
	Harness.equal(low, 2, "a time exactly on a key sits at its lower index")
	Harness.near(factor, 0, "so the weight is zero")

	low, high, factor = VecMath.bracketTimes(keys, 3)
	Harness.equal(low, 3, "between keys 2 and 4")
	Harness.equal(high, 4, "the upper key is the later one")
	Harness.near(factor, 0.5, "halfway between the pair")
end

local failures = Harness.report()
if failures > 0 then
	error(string.format("%d vecmath checks failed", failures), 0)
end
