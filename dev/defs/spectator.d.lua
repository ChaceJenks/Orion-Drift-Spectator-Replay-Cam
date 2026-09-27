--[[
	Definition file for the Orion Drift spectator camera scripting API.

	HAND-WRITTEN from the published reference at
	https://docs.spectator.oriondriftvr.com/reference/ , for the sole purpose of
	being able to strict-typecheck this camera without the game present. It is a
	secondary source: the *.d.lua files that ship with the client under

	    <install>\A2\Content\Scripts\Cameras\Behaviors\types\

	are authoritative. When you have the game installed, point luau-lsp at those
	instead (see README) - they will contain more members and the current
	signatures, and any disagreement between the two is a bug in this file.

	Two notes on the shape of this file:

	* Types are declared with local `type` aliases and only the values are
	  `declare`d. The analyzer's definitions dialect in current luau-lsp does not
	  accept `declare class` / `declare type`, so type NAMES do not leak into the
	  analyzed files. Code here therefore relies on inference for API values
	  instead of annotating them with API type names.
	* Vector and quaternion operators (`a + b`, `q * v`) exist at runtime through
	  metatables but cannot be expressed in this dialect, so all arithmetic in
	  this project goes through vecmath.luau.
]]

---- Math -----------------------------------------------------------------------

type Vec3 = {
	x: number,
	y: number,
	z: number,
	dot: (self: Vec3, other: Vec3) -> number,
	cross: (self: Vec3, other: Vec3) -> Vec3,
	length: (self: Vec3) -> number,
	squaredLength: (self: Vec3) -> number,
	normalize: (self: Vec3) -> Vec3,
	getSafeNormal: (self: Vec3) -> Vec3,
	lerp: (self: Vec3, other: Vec3, t: number) -> Vec3,
	distance: (self: Vec3, other: Vec3) -> number,
	rotateAngleAxis: (self: Vec3, degrees: number, axis: Vec3) -> Vec3,
	containsNan: (self: Vec3) -> boolean,
	isNearlyZero: (self: Vec3) -> boolean,
	getMax: (self: Vec3) -> number,
	getMin: (self: Vec3) -> number,
}

type Vec2 = {
	x: number,
	y: number,
}

type Quat = {
	x: number,
	y: number,
	z: number,
	w: number,
	euler: (self: Quat) -> Vec3,
	getForwardVector: (self: Quat) -> Vec3,
	getRightVector: (self: Quat) -> Vec3,
	getVector: (self: Quat) -> Vec3,
	getUpVector: (self: Quat) -> Vec3,
	inverse: (self: Quat) -> Quat,
	normalize: (self: Quat) -> Quat,
	rotateVector: (self: Quat, vector: Vec3) -> Vec3,
}

type Transform = {
	position: Vec3,
	rotation: Quat,
	scale: Vec3,
}

type DateTime = {
	ticks: number,
}

declare Vec3: {
	new: (x: number, y: number, z: number) -> Vec3,
	dot: (lhs: Vec3, rhs: Vec3) -> number,
	cross: (lhs: Vec3, rhs: Vec3) -> Vec3,
	lerp: (a: Vec3, b: Vec3, t: number) -> Vec3,
	distance: (a: Vec3, b: Vec3) -> number,
	upVector: Vec3,
	downVector: Vec3,
	rightVector: Vec3,
	leftVector: Vec3,
	forwardVector: Vec3,
	backwardVector: Vec3,
	zeroVector: Vec3,
	oneVector: Vec3,
}

declare Vec2: {
	new: (x: number, y: number) -> Vec2,
	zero: Vec2,
}

declare Quat: {
	new: (x: number, y: number, z: number, w: number) -> Quat,
	fromEuler: (roll: number, pitch: number, yaw: number) -> Quat,
	fromDirection: (direction: Vec3, fallback: Vec3?) -> Quat,
	fromXZ: (forward: Vec3, up: Vec3) -> Quat,
	findBetweenVectors: (from: Vec3, to: Vec3) -> Quat,
	slerp: (from: Quat, to: Quat, alpha: number) -> Quat,
	identity: Quat,
}

declare Transform: {
	new: (position: Vec3?, rotation: Quat?, scale: Vec3?) -> Transform,
	identity: Transform,
}

declare DateTime: {
	new: (ticks: number) -> DateTime,
	getCurrentTime: () -> DateTime,
}

---- Game data ------------------------------------------------------------------

type ReplayTransform = {
	position: Vec3,
	rotation: Quat,
	toJson: (self: ReplayTransform) -> string,
}

type ReplayPlayer = {
	playerId: number,
	playerName: string,
	isLocalPlayer: boolean,
	root: ReplayTransform,
	head: ReplayTransform,
	leftHand: ReplayTransform,
	rightHand: ReplayTransform,
	velocity: Vec3,
	leftThrusterActive: boolean,
	rightThrusterActive: boolean,
	isBraking: boolean,
	isBigBoosting: boolean,
	teamIndex: number,
	leftClimbing: boolean,
	rightClimbing: boolean,
	leftColliding: boolean,
	rightColliding: boolean,
	leftSliding: boolean,
	rightSliding: boolean,
	leftHandPosebits: number,
	rightHandPosebits: number,
	localClimbOffset: Vec3,
	grabbedByAnotherPlayerCounter: number,
	toJson: (self: ReplayPlayer) -> string,
}

type ReplayFrame = {
	time: DateTime,
	replayVersion: number,
	players: { ReplayPlayer },
	balls: { any },
	spectators: { any },
	worldTime: number,
	playersSeen: number,
	ballsSeen: number,
	getPlayerById: (self: ReplayFrame, playerId: number) -> ReplayPlayer,
	getPlayerByName: (self: ReplayFrame, name: string) -> ReplayPlayer,
	getLocalPlayer: (self: ReplayFrame) -> ReplayPlayer,
	toJson: (self: ReplayFrame) -> string,
}

declare function getGameData(): ReplayFrame
declare function getAllGameData(): { ReplayFrame }

---- Replay files ---------------------------------------------------------------

type Replay = {
	--- Should the time of this replay file automatically advance?
	isPlaying: boolean,
	setPlaybackTimeSeconds: (self: Replay, seconds: number) -> (),
	getPlaybackTimeSeconds: (self: Replay) -> number,
	setPlaybackTimestamp: (self: Replay, timestamp: DateTime) -> (),
	getPlaybackTimestamp: (self: Replay) -> DateTime,
	--- The timestamp of the first frame in the replay.
	getStartTime: (self: Replay) -> DateTime,
	--- The timestamp of the last frame in the replay.
	getEndTime: (self: Replay) -> DateTime,
	--- The duration of the replay in seconds.
	getDurationSeconds: (self: Replay) -> number,
	getCurrentFrame: (self: Replay, interpolate: boolean) -> ReplayFrame,
	getFrameAtTimeSeconds: (self: Replay, seconds: number, interpolate: boolean) -> ReplayFrame,
	getFrameAtTimestamp: (self: Replay, timestamp: DateTime, interpolate: boolean) -> ReplayFrame,
	--- Saves a segment to a new file, re-encoded with the newest replay version.
	saveSegmentToFile: (self: Replay, fileName: string, startSeconds: number, endSeconds: number) -> boolean,
}

declare Replay: {
	--- Loads a replay from the given fileName inside the standard replays folder.
	load: (fileName: string) -> Replay?,
	--- DEBUG: documented as "will be removed in the future"; avoid.
	loadSubsampled: (fileName: string, subsampleHz: number) -> Replay?,
	unloadAll: () -> (),
	unloadByIndex: (index: number) -> (),
	listAll: () -> { string },
	listLoaded: () -> { string },
	getByIndex: (index: number) -> Replay?,
	--- Starts recording to an automatically named file. False when Luau replay
	--- control is not allowed or a recording is already in progress.
	startRecording: () -> boolean,
	stopRecording: () -> boolean,
}

---- Camera ---------------------------------------------------------------------

type SpectatorCamera = {
	isActive: boolean,
	isFollowed: boolean,
	position: Vec3,
	rotation: Quat,
	positionSmoothing: number,
	rotationSmoothing: number,
	fieldOfView: number,
	fieldOfViewSmoothing: number,
	renderFirstPersonCamera: boolean,
	hideNearestHead: number,
	showNameTags: boolean,
	ignoreOcclusion: boolean,
	lookAt: (self: SpectatorCamera, target: Vec3, upVector: Vec3?) -> (),
	lookAtBasic: (self: SpectatorCamera, target: Vec3, upVector: Vec3?) -> (),
	followCamera: (self: SpectatorCamera, cameraToFollow: SpectatorCamera?) -> (),
	castRay: (self: SpectatorCamera, origin: Vec3, direction: Vec3, distance: number) -> any?,
	castRayFromMouse: (self: SpectatorCamera, distance: number) -> any?,
	getSmoothedPosition: (self: SpectatorCamera) -> Vec3,
	getSmoothedRotation: (self: SpectatorCamera) -> Quat,
	getSmoothedFieldOfView: (self: SpectatorCamera) -> number,
	getClosestGamemodeSlot: (self: SpectatorCamera) -> string,
	showQuestsForPlayerByName: (self: SpectatorCamera, playerName: string, show: boolean) -> (),
	showQuestsForPlayerById: (self: SpectatorCamera, playerId: number, show: boolean) -> (),
	setEmote: (self: SpectatorCamera, playerName: string, emoteId: number) -> (),
	getEmote: (self: SpectatorCamera, playerName: string) -> number,
}

type GravityComponent = {
	strength: number,
	center: Vec3,
	upRotation: Quat,
	upDirection: Vec3,
	rotationRate: number,
}

type PostProcessSettings = {
	brightness: number,
	contrast: number,
	exposure: number,
	saturation: number,
	tint: Vec3,
	depthOfFieldFocalDistance: number,
	depthOfFieldSensorWidth: number,
	depthOfFieldDepthBlurRadius: number,
	depthOfFieldDepthBlurAmount: number,
	depthOfFieldFstop: number,
	reset: (self: PostProcessSettings) -> (),
}

type Transition = {
	length: number,
	easeIn: number,
	easeOut: number,
	startTime: number,
	startPosition: Vec3,
	startRotation: Quat,
	startFieldOfView: number,
	mode: string,
}

declare camera: SpectatorCamera
declare gravity: GravityComponent
declare postProcessSettings: PostProcessSettings
declare alwaysTick: boolean
declare config: any

declare function getCameraById(cameraId: string): SpectatorCamera?
declare function sendMessage(targetCamera: any, message: any): ()
declare function saveConfig(): boolean

---- Input ----------------------------------------------------------------------

type KeyEnum = {
	-- Keyboard. Names are exactly as documented; note BackSpace, Asterix and the
	-- misspelt LeftParantheses/RightParantheses are the real identifiers.
	AnyKey: any, Tab: any, Enter: any, Pause: any, CapsLock: any, Escape: any,
	SpaceBar: any, PageUp: any, PageDown: any, End: any, Home: any,
	Left: any, Up: any, Right: any, Down: any, Insert: any, BackSpace: any, Delete: any,
	Zero: any, One: any, Two: any, Three: any, Four: any, Five: any, Six: any, Seven: any, Eight: any, Nine: any,
	A: any, B: any, C: any, D: any, E: any, F: any, G: any, H: any, I: any, J: any, K: any, L: any, M: any,
	N: any, O: any, P: any, Q: any, R: any, S: any, T: any, U: any, V: any, W: any, X: any, Y: any, Z: any,
	F1: any, F2: any, F3: any, F4: any, F5: any, F6: any, F7: any, F8: any, F9: any, F10: any, F11: any, F12: any,
	LeftShift: any, RightShift: any, LeftControl: any, RightControl: any, LeftAlt: any, RightAlt: any,
	LeftBracket: any, RightBracket: any, Semicolon: any, Equals: any, Comma: any, Hyphen: any,
	Underscore: any, Period: any, Slash: any, Tilde: any, Apostrophe: any,
	LeftParantheses: any, RightParantheses: any,
	NumLock: any, ScrollLock: any,
	-- Mouse, declared inside Key rather than in its own table.
	MouseX: any, MouseY: any, Mouse2D: any, MouseScrollUp: any, MouseScrollDown: any, MouseWheelAxis: any,
	LeftMouseButton: any, RightMouseButton: any, MiddleMouseButton: any,
	ThumbMouseButton: any, ThumbMouseButton2: any,
}

type GamepadEnum = {
	LeftX: any, LeftY: any, Left2D: any,
	RightX: any, RightY: any, Right2D: any,
	DPad_Up: any, DPad_Down: any, DPad_Left: any, DPad_Right: any,
	FaceButton_Bottom: any, FaceButton_Right: any, FaceButton_Left: any, FaceButton_Top: any,
	LeftShoulder: any, RightShoulder: any, LeftTrigger: any, RightTrigger: any,
	LeftTriggerAxis: any, RightTriggerAxis: any,
	LeftThumbstick: any, RightThumbstick: any,
}

declare Input: {
	Key: KeyEnum,
	Gamepad: GamepadEnum,
	getKey: (key: any) -> boolean,
	getKeyDown: (key: any) -> boolean,
	getKeyUp: (key: any) -> boolean,
	getAnalog: (key: any) -> number,
	getMouseDelta: () -> Vec2,
}

---- GUI ------------------------------------------------------------------------
-- Only the members this project uses. The widget set is immediate-mode (ImGui
-- shaped): widgets return their new value / whether they were activated.

-- Verified against the shipped gui.d.lua member list (59 members). There is no
-- tab, menu, colour, theme or image API in this build: the widget vocabulary is
-- text/separator/tree/combo/listbox/table plus the game-specific timeline,
-- rangeSlider, keyframeRow and graphEditor. Note the arity traps: dragFloat and
-- friends take (label, value, dragSpeed, min, max), while sliderFloat takes
-- (label, value, min, max); beginDisabled takes no arguments at all.
declare Gui: {
	text: (text: string) -> (),
	separatorText: (text: string) -> (),
	separator: () -> (),
	spacing: () -> (),
	newLine: () -> (),
	sameLine: () -> (),
	indent: () -> (),
	unindent: () -> (),
	sliderInt: (label: string, value: number, min: number, max: number) -> number,
	sliderFloat: (label: string, value: number, min: number, max: number) -> number,
	sliderFloat2: (label: string, value: Vec2, min: number, max: number) -> Vec2,
	sliderFloat3: (label: string, value: Vec3, min: number, max: number) -> Vec3,
	sliderFloat4: (label: string, value: Quat, min: number, max: number) -> Quat,
	dragInt: (label: string, value: number, dragSpeed: number, min: number, max: number) -> number,
	dragFloat: (label: string, value: number, dragSpeed: number, min: number, max: number) -> number,
	dragFloat2: (label: string, value: Vec2, dragSpeed: number, min: number, max: number) -> Vec2,
	dragFloat3: (label: string, value: Vec3, dragSpeed: number, min: number, max: number) -> Vec3,
	dragFloat4: (label: string, value: Quat, dragSpeed: number, min: number, max: number) -> Quat,
	vSliderFloat: (label: string, height: number, value: number, min: number, max: number) -> number,
	vSliderInt: (label: string, height: number, value: number, min: number, max: number) -> number,
	button: (label: string) -> boolean,
	smallButton: (label: string) -> boolean,
	checkbox: (label: string, value: boolean) -> boolean,
	collapsingHeader: (label: string) -> boolean,
	treeNode: (label: string) -> boolean,
	treePop: () -> (),
	beginDisabled: () -> (),
	endDisabled: () -> (),
	pushId: (id: string) -> (),
	popId: () -> (),
	inputText: (label: string, value: string) -> string,
	beginCombo: (label: string, previewValue: string) -> boolean,
	endCombo: () -> (),
	isItemHovered: () -> boolean,
	isItemActive: () -> boolean,
	isItemActivated: () -> boolean,
	isItemDeactivated: () -> boolean,
	selectable: (label: string, isSelected: boolean) -> boolean,
	setItemDefaultFocus: () -> boolean,
	beginTooltip: () -> boolean,
	endTooltip: () -> (),
	setItemTooltip: (text: string) -> (),
	beginHorizontal: (id: string) -> (),
	endHorizontal: () -> (),
	beginVertical: (id: string) -> (),
	endVertical: () -> (),
	beginListBox: (id: string) -> boolean,
	endListBox: () -> (),
	beginTable: (id: string, columnsCount: number) -> boolean,
	endTable: () -> (),
	tableSetupColumn: (id: string) -> (),
	tableHeadersRow: () -> (),
	tableNextRow: () -> (),
	tableNextColumn: () -> boolean,
	rangeSlider: (id: string, selectedRange: Vec2, min: number, max: number) -> Vec2,
	timeline: (id: string, playbackTime: number, startTime: number, endTime: number, snapTimeInterval: number) -> number,
	keyframeRow: (
		id: string,
		points: { Vec2 },
		playbackTime: number,
		startTime: number,
		endTime: number,
		snapTimeInterval: number
	) -> { Vec2 },
	graphEditor: (
		id: string,
		points: { Vec2 },
		playbackTime: number,
		startTime: number,
		endTime: number,
		snapTimeInterval: number
	) -> { Vec2 },
}

-- FontAwesome 5 free-solid glyph strings, meant to be concatenated into widget
-- labels. The real table has 995 members; only the ones used here are declared,
-- so a typo in a glyph name is a type error rather than a nil at runtime.
declare Icon: {
	Play: string,
	Pause: string,
	Stop: string,
	StepBackward: string,
	StepForward: string,
	FastBackward: string,
	FastForward: string,
	Sync: string,
	Undo: string,
	Redo: string,
	Camera: string,
	CameraRetro: string,
	Video: string,
	Film: string,
	Save: string,
	Trash: string,
	Plus: string,
	Times: string,
	Check: string,
	Eye: string,
	EyeSlash: string,
	LayerGroup: string,
	List: string,
	ListUl: string,
	Th: string,
	Search: string,
	FolderOpen: string,
	Clock: string,
	Compass: string,
	Crosshairs: string,
	SlidersH: string,
	Cog: string,
	Cogs: string,
	Keyboard: string,
	Bolt: string,
	TachometerAlt: string,
	ArrowsAlt: string,
	ChartLine: string,
	Download: string,
	Upload: string,
	Wrench: string,
	Key: string,
	Circle: string,
	ExclamationTriangle: string,
	InfoCircle: string,
}

---- Files, JSON, screenshots, settings ----------------------------------------

declare LuauFile: {
	--- Path is relative to the calling script's package folder.
	saveText: (path: string, text: string) -> boolean,
	loadText: (path: string) -> (string, boolean),
	listFiles: (path: string) -> { string },
}

declare LuauJson: {
	serialize: (value: any, pretty: boolean) -> string,
	parse: (text: string) -> any,
}

declare Screenshot: {
	--- 0 for the current render resolution. Returns the path of the saved image
	--- in Documents/Another-Axiom/A2/Screenshots, or an empty string on failure.
	takeScreenshot: (width: number, height: number) -> string,
}

declare Settings: {
	--- False when "control replays from luau" is off in the user's options, in
	--- which case startRecording/stopRecording always fail.
	getLuauReplayControlAllowed: () -> boolean,
}

---- Debug drawing --------------------------------------------------------------

declare WorldDraw: {
	drawPoint: (position: Vec3, size: number, r: number, g: number, b: number, thickness: number, lifeSeconds: number) -> (),
	drawLine: (from: Vec3, to: Vec3, r: number, g: number, b: number, thickness: number, lifeSeconds: number) -> (),
	clear: () -> (),
	clearAll: () -> (),
}

declare spectatorDebug: {
	goalExplosions: boolean,
	scrapRunSpinners: boolean,
	placeBallHereVisuals: boolean,
	replayBallScaleMultiplier: number,
}

---- Logging --------------------------------------------------------------------

declare function print(message: any): ()
declare function log(message: any): ()
declare function warn(message: any): ()
declare function issue(message: any): ()
declare function debug(message: any): ()
