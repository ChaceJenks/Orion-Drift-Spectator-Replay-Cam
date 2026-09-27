--!strict
--[[
	Shared type definitions for the replay camera.

	This module intentionally contains *no* calls into the spectator API. Every
	type here is either a plain value type or a structural description of an API
	object, which is what lets the logic modules (replaylayers, flycamera,
	shotfile) be driven by the unit tests with hand-written fakes.
]]

---- API shapes, described structurally -----------------------------------------

-- A vector as handed back by the spectator API. The API vectors carry metatable
-- operators, but the strict analyzer cannot see those through a definition file,
-- so all arithmetic in this project goes through vecmath instead of `+` / `*.
export type Vec3Struct = { x: number, y: number, z: number }

-- A quaternion as handed back by the spectator API.
export type QuatStruct = {
	x: number,
	y: number,
	z: number,
	w: number,
	getForwardVector: (self: QuatStruct) -> Vec3Struct,
	getRightVector: (self: QuatStruct) -> Vec3Struct,
	getUpVector: (self: QuatStruct) -> Vec3Struct,
	rotateVector: (self: QuatStruct, vector: Vec3Struct) -> Vec3Struct,
}

-- A timestamp as handed back by the spectator API. DateTime exposes nothing but
-- `ticks`, in 100 ns intervals since 0001-01-01, so all timestamp arithmetic in
-- this project is a subtraction scaled by 1e7.
export type DateTimeStruct = { ticks: number }

-- The subset of the Replay object that this camera actually touches. Kept
-- deliberately small so a test fake only has to implement these members; the
-- real object has more, and a wider table is assignable to this type.
export type ReplayHandle = {
	isPlaying: boolean,
	setPlaybackTimeSeconds: (self: ReplayHandle, seconds: number) -> (),
	getDurationSeconds: (self: ReplayHandle) -> number,
	getStartTime: (self: ReplayHandle) -> DateTimeStruct,
}

-- The subset of SpectatorCamera this camera drives. flycamera/camerapath stay
-- pure and never touch the camera object; main.luau is the only place that
-- writes to it, which keeps the maths testable without the client running.

---- Replay composition ---------------------------------------------------------

export type Overflow = string -- "hold" | "loop"
export type SyncMode = string -- "masterClock" | "independent"
export type AlignMode = string -- "relative" | "wallclock"
export type LoopMode = string -- "loop" | "stop" | "holdEnd"

-- One loaded replay inside the overlay. `duration` and `missing` are cached so
-- the timeline can be drawn without re-querying the handle every frame.
export type Layer = {
	file: string, -- basename as reported by Replay.listAll()
	label: string, -- shown in the Layers tab
	offset: number, -- seconds, added to the master clock
	overflow: Overflow, -- what to do when the master clock leaves the replay
	duration: number, -- seconds, cached
	startTicks: number, -- first frame timestamp, 0 when unknown
	missing: boolean, -- true when the handle could not be resolved
	handle: ReplayHandle?,
}

export type Composition = {
	syncMode: SyncMode,
	alignMode: AlignMode,
	loopMode: LoopMode,
	playing: boolean,
	speed: number,
	masterT: number, -- seconds from the start of the composition
	rangeStart: number, -- user-clipped timeline start
	rangeEnd: number, -- user-clipped timeline end, 0 means unset
}

---- Free-fly camera ------------------------------------------------------------

export type FlySettings = {
	moveSpeed: number, -- cm/s at 1x
	boostMultiplier: number,
	fineMultiplier: number,
	inertia: boolean,
	dampingTime: number, -- seconds to bleed off most velocity
	lookSensitivity: number,
	freeLook: boolean, -- look with the mouse without holding a button
	alignRoll: boolean, -- roll the camera to the local gravity
	positionSmoothing: number,
	rotationSmoothing: number,
	fov: number,
	followBuiltInFreecam: boolean,
}

-- Camera pose kept in plain numbers so the integrator is a pure function.
-- Yaw is measured from +X towards +Y, pitch is up-positive, both in degrees.
export type FlyState = {
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number,
	vx: number,
	vy: number,
	vz: number,
}

-- One frame of movement intent, all axes already normalised to -1..1.
export type FlyIntent = {
	forward: number,
	strafe: number,
	vertical: number,
	lookX: number,
	lookY: number,
	roll: number,
	boost: number, -- 1 = normal, >1 fast, <1 fine
}

---- Recorded camera path ------------------------------------------------------

export type PathKey = {
	t: number, -- seconds from the start of the shot
	x: number,
	y: number,
	z: number,
	rx: number,
	ry: number,
	rz: number,
	rw: number,
	fov: number,
}

export type CameraPath = {
	sampleHz: number,
	keys: { PathKey },
	offset: number, -- path time = composition clock + offset
}

-- A shot is the shareable "replay file recipe": which replays are stacked,
-- how they are aligned, and how the camera moves over them.
export type Shot = {
	version: number,
	name: string,
	syncMode: SyncMode,
	alignMode: AlignMode,
	loopMode: LoopMode,
	speed: number,
	rangeStart: number,
	rangeEnd: number,
	layers: { { file: string, label: string, offset: number, overflow: Overflow } },
	path: CameraPath?,
}

---- Recording ------------------------------------------------------------------

export type RecordPhase = string -- "idle" | "recording" | "finishing"
export type RecordState = {
	phase: RecordPhase,
	startTicks: number, -- DateTime.ticks when recording began
	elapsed: number, -- seconds, accumulated
	targetSeconds: number, -- auto-stop length; 0 records until you stop it by hand
	knownFiles: { string }, -- Replay.listAll() snapshot taken before startRecording
	currentFile: string, -- basename of the recording we produced, "" until known
	lastError: string,
}

---- Shared UI/error plumbing --------------------------------------------------

export type Notice = { kind: string, text: string } -- kind: "info" | "warn" | "error"

---- UI contract ---------------------------------------------------------------
-- The panel and the lifecycle code share one mutable model, so a widget can
-- write a setting or an offset straight through and the next tick picks it up.
-- `commands` therefore holds only the actions with side effects outside that
-- model: anything that calls into the client, touches the disk, or needs the
-- error guard.

export type Commands = {
	--- Re-reads the replay browser and re-resolves every layer handle.
	refresh: () -> (),
	addLayer: (file: string) -> (),
	removeLayer: (file: string) -> (),
	toggleRecording: () -> (),
	exportClip: () -> (),
	togglePathRecord: () -> (),
	toggleFreecam: () -> (),
	takeScreenshot: () -> (),
	saveShot: (name: string) -> (),
	loadShot: (name: string) -> (),
}

export type AppState = {
	-- Live model, shared with main.luau.
	comp: Composition,
	layers: { Layer },
	record: RecordState,
	fly: FlyState,
	settings: FlySettings,
	commands: Commands,

	-- Camera-path status, mirrored from the recorder for display.
	pathKeys: { PathKey },
	pathRecording: boolean,
	pathSampleHz: number,
	pathTruncated: boolean,
	pathOffset: number,

	-- Widget-only state and cached lists.
	section: string,
	notices: { Notice },
	files: { string },
	loadedFiles: { string },
	shotFiles: { string },
	shotName: string,
	clipName: string,
	clipStart: number,
	clipEnd: number,
	browserFilter: string,

	cameraMode: string, -- "manual" | "followPath" | "blend"
	ridingFreecam: boolean,

	-- Numbers the panel reports.
	flySpeed: number,
	framesPerSecond: number,
	syncErrors: number,
	errorCount: number,
	lastError: string,

	-- Which optional capabilities the running client actually offered.
	canControlReplays: boolean,
	canWriteReplays: boolean,
	canWriteFiles: boolean,
	canScreenshot: boolean,

	-- Settings that are not camera-movement maths.
	recordTargetSeconds: number,
	pathMaxKeys: number,
	pathBlend: number,
	layerCap: number,
	settingsDirty: boolean,
}

return nil
