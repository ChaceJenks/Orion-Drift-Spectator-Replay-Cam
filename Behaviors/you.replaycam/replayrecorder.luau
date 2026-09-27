--!strict
--[[
	Recording control.

	startRecording() picks its own file name, which is the one awkward part of the
	recording API: the call tells you *whether* it worked, not *what* it produced.
	So the state machine snapshots Replay.listAll() before starting and diffs it
	after stopping, which is how the exported-clip workflow knows which file it is
	operating on. If the diff is ambiguous (somebody else saved a replay in the
	same window, or the client wrote the file lazily) the result is reported as
	unknown and the Layers browser is the fallback rather than a wrong guess.

	Everything the client owns is injected, so the whole state machine is testable
	without the game.
]]

local Types = require("types")
local Util = require("util")

type RecordState = Types.RecordState
type Notice = Types.Notice

export type RecorderApi = {
	--- Basenames of every replay currently on disk.
	listAll: () -> { string },
	--- The client's own startRecording / stopRecording.
	startRecording: () -> boolean,
	stopRecording: () -> boolean,
	--- DateTime.ticks, injected so the elapsed maths can be tested.
	nowTicks: () -> number,
}

export type ClipHandle = {
	saveSegmentToFile: (self: ClipHandle, fileName: string, startSeconds: number, endSeconds: number) -> boolean,
}

export type ClipApi = {
	load: (fileName: string) -> ClipHandle?,
}

local ReplayRecorder = {}

local TICKS_PER_SECOND = 1e7

-- How long a recording runs before stopping itself. A minute is a useful default
-- here: long enough to cover a full rally and its aftermath, short enough that a
-- forgetful "leave it recording" does not fill the disk. Set the config value to
-- 0 to go back to stopping recordings by hand.
ReplayRecorder.defaultTargetSeconds = 60

function ReplayRecorder.newState(): RecordState
	return {
		phase = "idle",
		startTicks = 0,
		elapsed = 0,
		targetSeconds = ReplayRecorder.defaultTargetSeconds,
		knownFiles = {},
		currentFile = "",
		lastError = "",
	}
end

function ReplayRecorder.isRecording(state: RecordState): boolean
	return state.phase == "recording"
end

-- True once a fixed-length recording has run its length. Kept separate from
-- tick() so the caller decides what "stop" means (finish now, or finish on the
-- next frame after the on-screen counter visibly reaches the target).
function ReplayRecorder.shouldAutoStop(state: RecordState): boolean
	return state.phase == "recording"
		and state.targetSeconds > 0
		and state.elapsed >= state.targetSeconds
end

-- Advances the on-screen elapsed counter. Uses the same clock the client uses
-- for replay timestamps so the number matches the saved file.
function ReplayRecorder.tick(state: RecordState, api: RecorderApi): Notice?
	if state.phase ~= "recording" then
		return nil
	end
	local ticks, err = Util.try(api.nowTicks)
	if err ~= nil or ticks == nil then
		return { kind = "warn", text = "Could not read the clock: " .. (err or "nil") }
	end
	state.elapsed = Util.ticksToSeconds((ticks :: number) - state.startTicks)
	return nil
end

function ReplayRecorder.begin(state: RecordState, api: RecorderApi, targetSeconds: number?): { Notice }
	local notices: { Notice } = {}

	if state.phase == "recording" then
		table.insert(notices, { kind = "warn", text = "Already recording." })
		return notices
	end

	-- Decided up front so a refused start does not leave a stale target behind.
	local target = Util.num(targetSeconds, state.targetSeconds, 0, 3600)

	-- Snapshot before starting, so the after-the-fact diff has something to
	-- compare against. Failures here are not fatal: the diff just comes up empty.
	local listing, listError = Util.try(api.listAll)
	if listError ~= nil then
		state.knownFiles = {}
		table.insert(notices, { kind = "warn", text = "Could not list the replays folder: " .. listError })
	else
		local snapshot: { string } = {}
		for _, name in (listing :: { string }) do
			table.insert(snapshot, Util.basename(name))
		end
		state.knownFiles = snapshot
	end

	local started, startError = Util.try(api.startRecording)
	if startError ~= nil then
		state.phase = "idle"
		state.lastError = startError
		table.insert(notices, { kind = "error", text = "startRecording raised: " .. startError })
		return notices
	end

	if started ~= true then
		state.phase = "idle"
		state.lastError = "startRecording returned false"
		table.insert(
			notices,
			{
				kind = "error",
				text = "Recording refused. Either Luau replay control is switched off in the spectator options, or another camera already holds the recorder.",
			}
		)
		return notices
	end

	state.phase = "recording"
	state.currentFile = ""
	state.elapsed = 0
	state.targetSeconds = target
	local ticks = Util.try(api.nowTicks)
	state.startTicks = if type(ticks) == "number" then ticks :: number else 0
	if target > 0 then
		table.insert(
			notices,
			{ kind = "info", text = string.format("Recording started; will stop by itself at %s.", Util.formatTime(target)) }
		)
	else
		table.insert(notices, { kind = "info", text = "Recording started; it will run until you stop it." })
	end
	return notices
end

function ReplayRecorder.finish(state: RecordState, api: RecorderApi): { Notice }
	local notices: { Notice } = {}

	if state.phase ~= "recording" then
		table.insert(notices, { kind = "warn", text = "Not currently recording." })
		return notices
	end

	state.phase = "finishing"

	local stopped, stopError = Util.try(api.stopRecording)
	if stopError ~= nil then
		state.phase = "recording"
		state.lastError = stopError
		table.insert(notices, { kind = "error", text = "stopRecording raised: " .. stopError })
		return notices
	end
	if stopped ~= true then
		state.lastError = "stopRecording returned false"
		table.insert(notices, { kind = "warn", text = "stopRecording returned false; the file may still be open." })
	end

	-- Diff the folder against the pre-recording snapshot to find the new file.
	local listing, listError = Util.try(api.listAll)
	state.phase = "idle"
	if listError ~= nil then
		table.insert(notices, { kind = "warn", text = "Could not list the replays folder: " .. listError })
		return notices
	end

	local known: { [string]: boolean } = {}
	for _, name in state.knownFiles do
		known[name] = true
	end

	local newFiles: { string } = {}
	for _, name in (listing :: { string }) do
		local base = Util.basename(name)
		if not known[base] then
			table.insert(newFiles, base)
		end
	end

	if #newFiles == 1 then
		state.currentFile = newFiles[1]
		table.insert(
			notices,
			{ kind = "info", text = "Recording saved as " .. state.currentFile .. string.format(" (%s).", Util.formatTime(state.elapsed)) }
		)
	elseif #newFiles == 0 then
		state.currentFile = ""
		table.insert(
			notices,
			{
				kind = "warn",
				text = "Recording stopped, but no new file appeared yet. If the client writes it lazily, use Refresh in the Layers tab.",
			}
		)
	else
		state.currentFile = ""
		table.insert(
			notices,
			{
				kind = "warn",
				text = string.format(
					"Recording stopped, but %d new files appeared so the right one is ambiguous. Pick it in the Layers tab.",
					#newFiles
				),
			}
		)
	end

	state.elapsed = 0
	state.startTicks = 0
	state.knownFiles = {}
	return notices
end

-- Exports a marked range of a recording as a new .a2replay. The client
-- re-encodes the segment with the newest replay file version, which is why the
-- clip is the better artefact to share than the original recording.
function ReplayRecorder.exportClip(api: ClipApi, sourceFile: string, clipName: string, startSeconds: number, endSeconds: number): (boolean, { Notice })
	local notices: { Notice } = {}

	if #sourceFile == 0 then
		table.insert(notices, { kind = "error", text = "No recording selected. Pick one in the Layers tab first." })
		return false, notices
	end
	if not (endSeconds > startSeconds) then
		table.insert(notices, { kind = "error", text = "The clip range is empty - drag the range marks apart." })
		return false, notices
	end
	if #clipName == 0 then
		table.insert(notices, { kind = "error", text = "Pick a clip name." })
		return false, notices
	end

	local loaded, loadError = Util.try(function()
		return api.load(sourceFile)
	end)
	if loadError ~= nil or loaded == nil then
		table.insert(
			notices,
			{
				kind = "error",
				text = "Could not load " .. sourceFile .. " to clip it: " .. (loadError or "the client returned nil"),
			}
		)
		return false, notices
	end

	local handle = loaded :: ClipHandle
	local saved, saveError = Util.try(function()
		return handle:saveSegmentToFile(clipName, startSeconds, endSeconds)
	end)
	if saveError ~= nil then
		table.insert(notices, { kind = "error", text = "saveSegmentToFile raised: " .. saveError })
		return false, notices
	end
	if saved ~= true then
		table.insert(
			notices,
			{
				kind = "error",
				text = "The client refused to write the clip. Luau replay control is most likely switched off.",
			}
		)
		return false, notices
	end

	table.insert(notices, { kind = "info", text = "Clip written to " .. clipName .. ".a2replay" })
	return true, notices
end

-- Convenience for the UI: the elapsed time in seconds given a tick delta.
function ReplayRecorder.elapsedFromTicks(startTicks: number, nowTicks: number): number
	return (nowTicks - startTicks) / TICKS_PER_SECOND
end

return ReplayRecorder
