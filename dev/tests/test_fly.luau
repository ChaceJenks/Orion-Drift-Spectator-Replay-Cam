--!strict
--[[
	Tests for the free-fly integrator.

	The things a person notices immediately if these are wrong: flying backwards when
	W is pressed, a camera that rolls over when you look up, diagonal movement being
	faster than straight movement, and a camera that keeps drifting after you let go.
]]

local Harness = require("./harness")
local Fly = require("../pkg/flycamera")
local Types = require("../pkg/types")

type FlySettings = Types.FlySettings
type FlyIntent = Types.FlyIntent
type FlyState = Types.FlyState

Harness.suite("flycamera")

local function makeSettings(overrides: { [string]: any }?): FlySettings
	local base = {
		moveSpeed = 900,
		boostMultiplier = 4,
		fineMultiplier = 0.15,
		inertia = false,
		dampingTime = 0.35,
		lookSensitivity = 0.1,
		freeLook = false,
		alignRoll = false,
		positionSmoothing = 0,
		rotationSmoothing = 0,
		fov = 90,
		followBuiltInFreecam = false,
	}
	local values = (overrides or {}) :: { [string]: any }
	for key, value in pairs(values) do
		(base :: { [string]: any })[key] = value
	end
	return base :: any
end

local function makeIntent(overrides: { [string]: any }?): FlyIntent
	local base = { forward = 0, strafe = 0, vertical = 0, lookX = 0, lookY = 0, roll = 0, boost = 0 }
	local values = (overrides or {}) :: { [string]: any }
	for key, value in pairs(values) do
		(base :: { [string]: any })[key] = value
	end
	return base :: any
end

local settings = makeSettings(nil)

---- Speed selection ----------------------------------------------------------

Harness.near(Fly.speedFor(settings, 0), 900, "no modifier is the base speed")
Harness.near(Fly.speedFor(settings, 1), 3600, "the boost key multiplies speed")
Harness.near(Fly.speedFor(settings, -1), 135, "the fine key divides speed")
Harness.near(Fly.speedFor(makeSettings({ boostMultiplier = 1, fineMultiplier = 1 }), 1), 900, "a multiplier of 1 is no change")

---- Straight movement, no inertia --------------------------------------------

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ forward = 1 }), settings, 0.5, nil)
	Harness.near(state.x, 450, "half a second at 900 cm/s along +X")
	Harness.near(state.y, 0, "strafe untouched")
	Harness.near(state.z, 200, "level flight does not change altitude")
end

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ strafe = 1 }), settings, 1, nil)
	Harness.near(state.y, 900, "D strafes along +Y")
	Harness.near(state.x, 0, "without moving forward")
end

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ vertical = 1 }), settings, 1, nil)
	Harness.near(state.z, 1100, "E climbs along +Z")
end

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ vertical = -1 }), settings, 1, nil)
	Harness.near(state.z, -700, "Q descends along -Z")
end

do
	-- Backwards while looking along +X means -X, not +X. This is the single most
	-- obvious way a flight camera can feel broken.
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ forward = -1 }), settings, 1, nil)
	Harness.near(state.x, -900, "S reverses along -X")
end

do
	-- Pitch should not change ground speed: looking up and flying forward covers
	-- less horizontal distance but the same total distance.
	local state = Fly.newState(0, 0, 200, 0, 45)
	Fly.step(state, makeIntent({ forward = 1 }), settings, 1, nil)
	Harness.near(math.abs(state.x), 900 * math.cos(math.rad(45)), "looking up 45 degrees moves along the look vector", 1e-3)
	local horizontal = math.abs(state.x)
	local vertical = math.abs(state.z - 200)
	Harness.near(math.sqrt(horizontal * horizontal + vertical * vertical), 900, "total distance is still one second of speed", 1e-3)
end

---- Diagonal normalisation ---------------------------------------------------

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ forward = 1, strafe = 1 }), settings, 1, nil)
	local travelled = math.sqrt(state.x * state.x + state.y * state.y)
	Harness.near(travelled, 900, "forward plus strafe is not 1.41x faster", 1e-3)
	Harness.near(state.x, state.y, "and the diagonal is symmetric", 1e-3)
end

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ forward = 1, strafe = 1, vertical = 1 }), settings, 1, nil)
	local travelled = math.sqrt(state.x * state.x + state.y * state.y + (state.z - 200) * (state.z - 200))
	Harness.near(travelled, 900, "three axes at once is still one second of speed", 1e-3)
end

do
	-- A stuck input reporting 2 instead of 1 must not double the speed either.
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ forward = 2 }), settings, 1, nil)
	Harness.near(math.abs(state.x), 900, "an over-range axis is normalised", 1e-3)
end

---- Look ---------------------------------------------------------------------

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ lookX = 100 }), settings, 1 / 60, nil)
	Harness.near(state.yaw, 10, "mouse right turns yaw by delta times sensitivity")
end

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ lookY = 100 }), settings, 1 / 60, nil)
	Harness.near(state.pitch, 10, "the caller's up-positive delta raises the nose")
end

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ lookY = 100000 }), settings, 1 / 60, nil)
	Harness.near(state.pitch, 89.5, "pitch stops short of the pole")
	Fly.step(state, makeIntent({ lookY = -100000 }), settings, 1 / 60, nil)
	Harness.near(state.pitch, -89.5, "and short of the other pole")
end

do
	-- Long sessions of small mouse movements must not let yaw drift past the wrap,
	-- where trig precision starts to fall away.
	local state = Fly.newState(0, 0, 200, 175, 0)
	Fly.step(state, makeIntent({ lookX = 100 }), settings, 1 / 60, nil)
	Harness.near(state.yaw, -175, "yaw wraps through 180 rather than growing")
	local spinning = Fly.newState(0, 0, 200, 0, 0)
	for _ = 1, 1000 do
		Fly.step(spinning, makeIntent({ lookX = 400 }), settings, 1 / 60, nil)
	end
	Harness.check(math.abs(spinning.yaw) <= 180, "a thousand turns still report an angle in range")
end

do
	-- Look is applied before the move in the same frame, so a turn-while-flying
	-- follows the new heading immediately instead of lagging a frame behind.
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ forward = 1, lookX = 900 }), settings, 1, nil)
	Harness.near(state.yaw, 90, "the turn lands in the same frame")
	Harness.near(state.y, 900, "so the movement follows the new heading", 1e-3)
	Harness.near(state.x, 0, "and not the old one", 1e-3)
end

---- Inertia ------------------------------------------------------------------

do
	-- With smoothing on, releasing the keys should coast to a stop rather than halt
	-- instantly, but it must actually arrive at a stop.
	local state = Fly.newState(0, 0, 200, 0, 0)
	local gliding = makeSettings({ inertia = true })
	Fly.step(state, makeIntent({ forward = 1 }), gliding, 1 / 60, nil)
	local launched = Fly.speed(state)
	Harness.check(launched > 0 and launched < 900, "a first frame with inertia is still accelerating")

	for _ = 1, 600 do
		Fly.step(state, makeIntent({ forward = 1 }), gliding, 1 / 60, nil)
	end
	Harness.near(Fly.speed(state), 900, "held long enough it reaches the requested speed", 1)

	for _ = 1, 600 do
		Fly.step(state, makeIntent(nil), gliding, 1 / 60, nil)
	end
	Harness.near(Fly.speed(state), 0, "and it comes to rest after release", 1)
end

do
	-- With smoothing off the camera has to stop dead; otherwise tapping a key in a
	-- still shot would drift.
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ forward = 1 }), settings, 1 / 60, nil)
	Fly.step(state, makeIntent(nil), settings, 1 / 60, nil)
	Harness.near(Fly.speed(state), 0, "no inertia means no coast")
end

do
	local state = Fly.newState(100, 200, 300, 12, 3)
	Fly.stopMotion(state)
	Harness.near(Fly.speed(state), 0, "stopMotion zeroes the velocity")
	Harness.near(state.x, 100, "without moving the camera")
	Harness.near(state.yaw, 12, "and without turning it")
end

---- Frame-rate and degenerate input -----------------------------------------

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ forward = 1 }), settings, 0, nil)
	Harness.near(state.x, 0, "a zero dt moves nothing")
	Fly.step(state, makeIntent({ forward = 1 }), settings, -1, nil)
	Harness.near(state.x, 0, "and a negative dt is ignored rather than rewinding")
end

do
	-- A hitch can hand the integrator a huge dt. The position clamp is what keeps
	-- that from sending the camera to infinity and losing the scene.
	local state = Fly.newState(0, 0, 200, 0, 0)
	Fly.step(state, makeIntent({ forward = 1 }), settings, 1e9, nil)
	Harness.check(math.abs(state.x) <= 1e9, "an absurd dt is clamped to a sane coordinate")
	Harness.near(Fly.speed(state), 0, "and the velocity is cleared with it")
end

do
	-- NaN is the unrecoverable case: nothing downstream can compare against it, so
	-- the integrator has to heal itself or the camera is lost for the session.
	local poisoned = Fly.newState(0 / 0, 200, 300, 0, 0)
	Fly.step(poisoned, makeIntent({ forward = 1 }), settings, 1 / 60, nil)
	Harness.check(poisoned.x == poisoned.x, "a NaN position is repaired")
	local spun = Fly.newState(0, 0, 200, 0 / 0, 0)
	Fly.step(spun, makeIntent(nil), settings, 1 / 60, nil)
	Harness.check(spun.yaw == spun.yaw, "a NaN yaw is repaired")
	Harness.near(math.abs(spun.yaw), 0, "and reset to a usable angle")
end

do
	-- Every step has to return the same table it was handed: main.luau keeps one
	-- FlyState alive for the session and the panel reads it, so returning a copy
	-- would silently freeze the HUD readout.
	local state = Fly.newState(0, 0, 0, 0, 0)
	local returned = Fly.step(state, makeIntent({ forward = 1 }), settings, 1 / 60, nil)
	Harness.check(returned == state, "step mutates and returns the same state")
end

---- Pose output --------------------------------------------------------------

do
	local state = Fly.newState(0, 0, 200, 0, 0)
	local target, up = Fly.lookTarget(state, nil)
	Harness.near(target.x, 100, "the look target is a metre ahead along +X")
	Harness.near(target.y, 0, "with no lateral offset")
	Harness.near(target.z, 200, "at eye height")
	Harness.near(up.z, 1, "and hands lookAt a +Z up vector, not an inverted one", 1e-9)
end

do
	-- The rotate hook is how gravity alignment reaches the basis: whatever it
	-- returns is what the camera uses for forward, so a rotation of the world axes
	-- must show up in the target.
	local state = Fly.newState(0, 0, 0, 0, 0)
	local function turnLeft(x: number, y: number, z: number)
		return { x = -y, y = x, z = z }
	end
	local target = Fly.lookTarget(state, turnLeft)
	Harness.near(target.x, 0, "the rotate hook is applied to forward", 1e-9)
	Harness.near(target.y, 100, "turning the axes turns the view", 1e-9)
end

do
	local state = Fly.newState(1, 2, 3, 45, 6)
	local copy = Fly.clone(state)
	Harness.check(copy ~= state, "clone makes a separate table")
	Harness.near(copy.x, 1, "carrying the position")
	Harness.near(copy.yaw, 45, "and the angles")
	copy.x = 99
	Harness.near(state.x, 1, "editing the clone leaves the original alone")
end

local failures = Harness.report()
if failures > 0 then
	error(string.format("%d flycamera checks failed", failures), 0)
end
