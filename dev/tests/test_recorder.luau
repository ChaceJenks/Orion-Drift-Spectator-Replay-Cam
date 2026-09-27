--!strict
--[[
	Tests for the recording state machine, including the fixed-length recording
	and the listAll-diff that identifies which file the client wrote.
]]

local Harness = require("./harness")
local Recorder = require("../pkg/replayrecorder")
local Types = require("../pkg/types")

type RecordState = Types.RecordState
type Notice = Types.Notice

Harness.suite("replayrecorder")

---- Fakes --------------------------------------------------------------------
-- Built with a forward-declared local rather than a table literal, because a
-- closure written inside a table literal cannot capture the local it is being
-- assigned to: `local api = { f = function() return api.x end }` silently reads
-- a *global* `api` and yields nil. Declaring the local first is what makes the
-- capture real.

type FakeApi = {
	listAll: () -> { string },
	startRecording: () -> boolean,
	stopRecording: () -> boolean,
	nowTicks: () -> number,

	_files: { string },
	_clock: number,
	_startResult: boolean,
	_stopResult: boolean,
	_startCalls: number,
	_stopCalls: number,
}

local function fakeApi(): FakeApi
	local api: any = {}
	api._files = { "oldmatch.a2replay" }
	api._clock = 1_000 * 1e7
	api._startResult = true
	api._stopResult = true
	api._startCalls = 0
	api._stopCalls = 0
	api.listAll = function()
		return api._files
	end
	api.startRecording = function(): boolean
		api._startCalls += 1
		return api._startResult
	end
	api.stopRecording = function(): boolean
		api._stopCalls += 1
		return api._stopResult
	end
	api.nowTicks = function(): number
		return api._clock
	end
	return api
end

local function noticeText(notices: { Notice }): string
	local parts: { string } = {}
	for _, notice in notices do
		table.insert(parts, notice.kind .. ":" .. notice.text)
	end
	return table.concat(parts, " | ")
end

---- Default length is one minute ---------------------------------------------

do
	local state = Recorder.newState()
	Harness.near(state.targetSeconds, 60, "a fresh recorder defaults to a one minute recording")
	Harness.equal(state.phase, "idle", "and starts idle")

	local api = fakeApi()
	local notices = Recorder.begin(state, api, nil)
	Harness.equal(state.phase, "recording", "begin starts recording")
	Harness.near(state.targetSeconds, 60, "the one minute target survives begin")
	Harness.equal(api._startCalls, 1, "startRecording called once")
	Harness.check(
		string.find(noticeText(notices), "stop by itself at 01:00", 1, true) ~= nil,
		"the notice states the one minute target"
	)
end

---- The auto-stop itself -----------------------------------------------------

do
	local state = Recorder.newState()
	local api = fakeApi()
	Recorder.begin(state, api, 60)

	-- 20 seconds in: still running.
	api._clock = (1_000 + 20) * 1e7
	Recorder.tick(state, api)
	Harness.near(state.elapsed, 20, "elapsed tracks the client clock")
	Harness.equal(Recorder.shouldAutoStop(state), false, "not yet at one minute")

	-- 59.9 seconds: still running, so the counter can be seen reaching the mark.
	api._clock = (1_000 + 59.9) * 1e7
	Recorder.tick(state, api)
	Harness.near(state.elapsed, 59.9, "elapsed accumulates fractions of a second", 1e-4)
	Harness.equal(Recorder.shouldAutoStop(state), false, "59.9 s has not reached the target")

	-- One minute exactly: stop.
	api._clock = (1_000 + 60) * 1e7
	Recorder.tick(state, api)
	Harness.equal(Recorder.shouldAutoStop(state), true, "stops at exactly one minute")

	-- And it stays true rather than firing once and going quiet.
	Harness.equal(Recorder.shouldAutoStop(state), true, "the stop condition holds until the caller finishes")
end

do
	-- A custom length must be honoured, and 0 must mean "never".
	local state = Recorder.newState()
	local api = fakeApi()
	Recorder.begin(state, api, 90)
	api._clock = (1_000 + 61) * 1e7
	Recorder.tick(state, api)
	Harness.equal(Recorder.shouldAutoStop(state), false, "a 90 s target does not stop at 61 s")
	api._clock = (1_000 + 91) * 1e7
	Recorder.tick(state, api)
	Harness.equal(Recorder.shouldAutoStop(state), true, "and does stop past 90 s")

	local manual = Recorder.newState()
	Recorder.begin(manual, api, 0)
	api._clock = (1_000 + 3600) * 1e7
	Recorder.tick(manual, api)
	Harness.equal(Recorder.shouldAutoStop(manual), false, "target 0 records until stopped by hand")
end

do
	-- Auto-stop must not fire when nothing is recording.
	local state = Recorder.newState()
	state.elapsed = 500
	Harness.equal(Recorder.shouldAutoStop(state), false, "an idle recorder never asks to stop")
end

---- Refusals -----------------------------------------------------------------

do
	local state = Recorder.newState()
	local api = fakeApi()
	api._startResult = false
	local notices = Recorder.begin(state, api, 60)
	Harness.equal(state.phase, "idle", "a refused start leaves the state idle")
	Harness.check(string.find(noticeText(notices), "Luau replay control", 1, true) ~= nil, "the refusal names the likely cause")
end

do
	local state = Recorder.newState()
	local api = fakeApi()
	Recorder.begin(state, api, 60)
	local notices = Recorder.begin(state, api, 60)
	Harness.equal(api._startCalls, 1, "starting twice does not call the client twice")
	Harness.check(string.find(noticeText(notices), "Already recording", 1, true) ~= nil, "and warns instead")
end

---- Which file did we just write? --------------------------------------------

do
	local state = Recorder.newState()
	local api = fakeApi()
	Recorder.begin(state, api, 60)
	-- The client writes the recording under its own name; it appears in listAll.
	table.insert(api._files, "Recordings/auto-20260729.a2replay")
	local notices = Recorder.finish(state, api)
	Harness.equal(state.currentFile, "auto-20260729.a2replay", "the new file is identified by basename")
	Harness.equal(state.phase, "idle", "and the recorder returns to idle")
	Harness.check(string.find(noticeText(notices), "auto-20260729", 1, true) ~= nil, "the notice names the saved file")
	Harness.equal(api._stopCalls, 1, "stopRecording called once")
end

do
	-- Two new files at once is genuinely ambiguous: report it, never guess.
	local state = Recorder.newState()
	local api = fakeApi()
	Recorder.begin(state, api, 60)
	table.insert(api._files, "one.a2replay")
	table.insert(api._files, "two.a2replay")
	local notices = Recorder.finish(state, api)
	Harness.equal(state.currentFile, "", "an ambiguous result claims no file")
	Harness.check(string.find(noticeText(notices), "2 new files", 1, true) ~= nil, "and says how many appeared")
end

do
	-- No new file (the client may flush lazily): warn, do not error, and keep the
	-- recorder usable for a retry.
	local state = Recorder.newState()
	local api = fakeApi()
	Recorder.begin(state, api, 60)
	local notices = Recorder.finish(state, api)
	Harness.check(string.find(noticeText(notices), "no new file", 1, true) ~= nil, "a missing file is reported")
	Harness.equal(state.phase, "idle", "the recorder is still usable afterwards")
end

---- Clip export --------------------------------------------------------------

type FakeClip = {
	saveSegmentToFile: (self: FakeClip, name: string, startSeconds: number, endSeconds: number) -> boolean,
	_calls: { { string } },
	_result: boolean,
}

local function fakeClip(result: boolean): FakeClip
	local clip: any = {}
	clip._calls = {}
	clip._result = result
	clip.saveSegmentToFile = function(self: any, name: string, startSeconds: number, endSeconds: number): boolean
		table.insert(self._calls, { name, tostring(startSeconds), tostring(endSeconds) })
		return self._result
	end
	return clip
end

-- Declared as the real ClipApi shape, so a drift in that shape is a compile error
-- here rather than a surprise at runtime.
local function clipApi(clip: FakeClip?): Recorder.ClipApi
	return {
		load = function(_fileName: string): Recorder.ClipHandle?
			if clip == nil then
				return nil
			end
			return clip :: any
		end,
	}
end

do
	local clip = fakeClip(true)
	local ok, notices = Recorder.exportClip(clipApi(clip), "match.a2replay", "best_rally", 12, 47)
	Harness.equal(ok, true, "a successful export reports success")
	Harness.equal(#clip._calls, 1, "saveSegmentToFile called once")
	Harness.equal(clip._calls[1][1], "best_rally", "with the requested clip name")
	Harness.equal(clip._calls[1][2], "12", "with the range start")
	Harness.equal(clip._calls[1][3], "47", "with the range end")
	Harness.equal(#notices, 1, "one informational notice on success")
end

do
	local ok, notices = Recorder.exportClip(clipApi(nil), "gone.a2replay", "clip", 0, 10)
	Harness.equal(ok, false, "a file that will not load fails the export")
	Harness.equal(#notices, 1, "and produces exactly one error notice")
end

do
	local ok = Recorder.exportClip(clipApi(fakeClip(false)), "match.a2replay", "clip", 0, 10)
	Harness.equal(ok, false, "a client refusal is reported as a failure")
end

do
	local clip = fakeClip(true)
	local api = clipApi(clip)
	Harness.equal(Recorder.exportClip(api, "", "clip", 0, 10), false, "no source file selected")
	Harness.equal(Recorder.exportClip(api, "match.a2replay", "", 0, 10), false, "no clip name")
	Harness.equal(Recorder.exportClip(api, "match.a2replay", "clip", 30, 30), false, "an empty range")
	Harness.equal(Recorder.exportClip(api, "match.a2replay", "clip", 40, 10), false, "an inverted range")
	Harness.equal(#clip._calls, 0, "none of those reached the client")
end

local failures = Harness.report()
if failures > 0 then
	error(string.format("%d replayrecorder checks failed", failures), 0)
end
