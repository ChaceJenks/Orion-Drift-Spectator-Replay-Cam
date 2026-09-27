--!strict
--[[
	Free-fly camera movement and look.

	Pure: this module never touches the camera object, the Input API or the
	gravity component. main.luau reads the device state, calls step(), then writes
	the result to the camera. That split is what makes the movement maths unit
	testable, and it keeps a single obvious place where engine state is mutated.

	Signed conventions, worth stating once:
	  intent.forward  +1 = W (along the look direction)
	  intent.strafe   +1 = D (right)
	  intent.vertical +1 = E (along gravity's up, or world +Z in zero-g)
	  intent.lookX    +1 = mouse moved right  (yaw increases)
	  intent.lookY    +1 = look UP            (callers negate the mouse delta)
]]

local Types = require("types")
local Util = require("util")
local VecMath = require("vecmath")

type FlyState = Types.FlyState
type FlySettings = Types.FlySettings
type FlyIntent = Types.FlyIntent
type Vec3Struct = Types.Vec3Struct

-- Rotates a gravity-frame axis into world space. main.luau passes
-- gravity.upRotation.rotateVector; nil means the axes are already world axes.
export type AxisRotate = ((number, number, number) -> Vec3Struct)?

local Fly = {}

function Fly.newState(x: number, y: number, z: number, yaw: number, pitch: number): FlyState
	return {
		x = x,
		y = y,
		z = z,
		yaw = yaw,
		pitch = VecMath.clampPitch(pitch),
		vx = 0,
		vy = 0,
		vz = 0,
	}
end

-- Copies a state so a caller can keep a snapshot (used when adopting the pose of
-- another camera without inheriting its velocity).
function Fly.clone(state: FlyState): FlyState
	return {
		x = state.x,
		y = state.y,
		z = state.z,
		yaw = state.yaw,
		pitch = state.pitch,
		vx = state.vx,
		vy = state.vy,
		vz = state.vz,
	}
end

-- Drops all momentum without moving the camera. Bound to a key so a shot can be
-- held rock steady after a fast move.
function Fly.stopMotion(state: FlyState)
	state.vx = 0
	state.vy = 0
	state.vz = 0
end

function Fly.speedFor(settings: FlySettings, boost: number): number
	local multiplier = if boost > 0 then settings.boostMultiplier else if boost < 0 then settings.fineMultiplier else 1
	return math.max(0, settings.moveSpeed * multiplier)
end

-- World-space movement basis for the current look angles.
function Fly.basis(state: FlyState, rotate: AxisRotate): (Vec3Struct, Vec3Struct, Vec3Struct)
	local forward, right, up = VecMath.basisFromAngles(state.yaw, state.pitch)
	if rotate == nil then
		return forward, right, up
	end
	local rotateAxis = rotate :: (number, number, number) -> Vec3Struct
	return rotateAxis(forward.x, forward.y, forward.z),
		rotateAxis(right.x, right.y, right.z),
		rotateAxis(up.x, up.y, up.z)
end

--[[
	Advances the pose by dt seconds. Mutates and returns `state`.

	Look is applied first so that this frame's movement uses this frame's
	direction: when you flick the mouse and hold W, the camera should start moving
	where it is now pointing, not where it pointed last frame.
]]
function Fly.step(state: FlyState, intent: FlyIntent, settings: FlySettings, dt: number, rotate: AxisRotate): FlyState
	if dt <= 0 then
		return state
	end

	---- Look
	if intent.lookX ~= 0 or intent.lookY ~= 0 then
		local sensitivity = settings.lookSensitivity
		state.yaw = VecMath.wrapAngle(state.yaw + intent.lookX * sensitivity)
		state.pitch = VecMath.clampPitch(state.pitch + intent.lookY * sensitivity)
	end

	---- Move
	local forward, right, up = Fly.basis(state, rotate)
	local speed = Fly.speedFor(settings, intent.boost)

	local wishX = forward.x * intent.forward * speed + right.x * intent.strafe * speed + up.x * intent.vertical * speed
	local wishY = forward.y * intent.forward * speed + right.y * intent.strafe * speed + up.y * intent.vertical * speed
	local wishZ = forward.z * intent.forward * speed + right.z * intent.strafe * speed + up.z * intent.vertical * speed

	-- Normalise diagonals so moving forward-and-right is not 1.41x faster. The
	-- wish vector is built from an orthonormal basis times three axis weights, so
	-- its length is speed * sqrt(sum of squares of the axes actually in use).
	local axisMagnitude = math.sqrt(
		intent.forward * intent.forward + intent.strafe * intent.strafe + intent.vertical * intent.vertical
	)
	if axisMagnitude > 1 then
		wishX = wishX / axisMagnitude
		wishY = wishY / axisMagnitude
		wishZ = wishZ / axisMagnitude
	end

	if settings.inertia then
		state.vx = Util.exponentialSmoothing(state.vx, wishX, settings.dampingTime, dt)
		state.vy = Util.exponentialSmoothing(state.vy, wishY, settings.dampingTime, dt)
		state.vz = Util.exponentialSmoothing(state.vz, wishZ, settings.dampingTime, dt)
	else
		state.vx = wishX
		state.vy = wishY
		state.vz = wishZ
	end

	state.x += state.vx * dt
	state.y += state.vy * dt
	state.z += state.vz * dt

	-- A long session at high speed can push coordinates far enough that the
	-- trig and the client's own transform maths start losing precision. The
	-- arenas here are at most a few hundred thousand cm across.
	if math.abs(state.x) > 1e9 or math.abs(state.y) > 1e9 or math.abs(state.z) > 1e9 then
		state.x = Util.clamp(state.x, -1e9, 1e9)
		state.y = Util.clamp(state.y, -1e9, 1e9)
		state.z = Util.clamp(state.z, -1e9, 1e9)
		state.vx = 0
		state.vy = 0
		state.vz = 0
	end

	-- A NaN is invisible to the comparisons above, and unlike an out-of-range value
	-- it never recovers: every later frame reads the poisoned number back and
	-- multiplies the damage. So it is detected by its one property - it does not
	-- equal itself - and the affected component is reset. Losing the position is
	-- survivable; keeping a NaN means a camera that has to be reloaded.
	if not (state.x == state.x) or not (state.y == state.y) or not (state.z == state.z)
		or not (state.yaw == state.yaw) or not (state.pitch == state.pitch) then
		if not (state.x == state.x) then
			state.x = 0
		end
		if not (state.y == state.y) then
			state.y = 0
		end
		if not (state.z == state.z) then
			state.z = 0
		end
		if not (state.yaw == state.yaw) then
			state.yaw = 0
		end
		if not (state.pitch == state.pitch) then
			state.pitch = 0
		end
		state.vx = 0
		state.vy = 0
		state.vz = 0
	end

	return state
end

-- The look target for camera:lookAt, one metre ahead of the eye. Kept here so
-- the "where am I pointing" maths has exactly one definition.
function Fly.lookTarget(state: FlyState, rotate: AxisRotate): (Vec3Struct, Vec3Struct)
	local forward, _, up = Fly.basis(state, rotate)
	local distance = 100 -- cm; the client normalises the direction, the value only needs to be non-zero
	return { x = state.x + forward.x * distance, y = state.y + forward.y * distance, z = state.z + forward.z * distance }, up
end

-- Velocity magnitude, for the HUD line.
function Fly.speed(state: FlyState): number
	return VecMath.length(state.vx, state.vy, state.vz)
end

return Fly
