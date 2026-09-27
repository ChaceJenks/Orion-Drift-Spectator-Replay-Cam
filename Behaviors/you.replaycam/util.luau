--!strict
--[[
	Small helpers shared by every module: config coercion, formatting, path
	handling and error normalisation.

	The config coercion functions matter more than they look. The camera's config
	lives in a plain .json file that the docs explicitly encourage editing by
	hand, and `config` arrives as an untyped table. Every value read back out is
	therefore coerced and range-checked rather than trusted.
]]

local Types = require("types")
type Notice = Types.Notice

local Util = {}

local DEFAULT_TICKS_PER_SECOND = 1e7 -- .NET/Unreal DateTime ticks are 100ns

---- Numbers --------------------------------------------------------------------

function Util.clamp(value: number, low: number, high: number): number
	if value < low then
		return low
	elseif value > high then
		return high
	end
	return value
end

function Util.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Exponential smoothing that is stable for any dt. `timeConstant` is the time
-- in seconds to close most of the gap, matching how the client describes its
-- own camera smoothing values.
function Util.exponentialSmoothing(current: number, target: number, timeConstant: number, dt: number): number
	if timeConstant <= 0 or dt <= 0 then
		return target
	end
	local alpha = 1 - math.exp(-dt / timeConstant)
	return current + (target - current) * alpha
end

function Util.isFiniteNumber(value: number): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

---- Config coercion ------------------------------------------------------------
-- Each reader accepts whatever the json actually contains and returns a value
-- that is safe to use, falling back to the default on anything unusable.

function Util.num(value: any, default: number, low: number?, high: number?): number
	local result = default
	if type(value) == "number" and Util.isFiniteNumber(value :: number) then
		result = value :: number
	elseif type(value) == "string" then
		local parsed = tonumber(value :: string)
		if parsed ~= nil and Util.isFiniteNumber(parsed) then
			result = parsed
		end
	end
	if low ~= nil then
		result = math.max(low, result)
	end
	if high ~= nil then
		result = math.min(high, result)
	end
	return result
end

function Util.int(value: any, default: number, low: number?, high: number?): number
	return math.floor(Util.num(value, default, low, high) + 0.5)
end

function Util.bool(value: any, default: boolean): boolean
	if value == nil then
		return default
	end
	return value == true
end

function Util.str(value: any, default: string): string
	if type(value) == "string" and #(value :: string) > 0 then
		return value :: string
	end
	return default
end

function Util.enum(value: any, options: { string }, default: string): string
	if type(value) == "string" then
		for _, option in options do
			if option == value then
				return option
			end
		end
	end
	return default
end

-- Returns the keys that were missing, so the caller can mention them once in
-- the log instead of silently papering over a hand-broken config file.
function Util.applyDefaults(config: any, defaults: { [string]: any }): { string }
	local missing: { string } = {}
	if type(config) ~= "table" then
		return missing
	end
	local entries = config :: { [string]: any }
	for key, default in defaults do
		if entries[key] == nil then
			entries[key] = default
			table.insert(missing, key)
		end
	end
	table.sort(missing)
	return missing
end

---- Time -----------------------------------------------------------------------

function Util.ticksToSeconds(ticks: number): number
	return ticks / DEFAULT_TICKS_PER_SECOND
end

function Util.secondsToTicks(seconds: number): number
	return math.floor(seconds * DEFAULT_TICKS_PER_SECOND + 0.5)
end

-- mm:ss.ms, safe for negative, infinite, NaN and absurd inputs.
function Util.formatTime(seconds: number): string
	if not Util.isFiniteNumber(seconds) then
		return "--:--"
	end
	local sign = if seconds < 0 then "-" else ""
	local absolute = math.abs(seconds)
	local minutes = math.floor(absolute / 60)
	local rest = absolute - minutes * 60
	return string.format("%s%02d:%05.2f", sign, minutes, rest)
end

-- A short stamp for generated file names. Built from DateTime ticks so it does
-- not depend on any time library being available to camera scripts.
function Util.stampFromTicks(ticks: number): string
	-- Ticks since 0001-01-01; convert to days, then to a y-m-d H:M:S shape.
	local totalSeconds = math.floor(Util.ticksToSeconds(ticks))
	local days = math.floor(totalSeconds / 86400)
	local timeOfDay = totalSeconds - days * 86400
	local hour = math.floor(timeOfDay / 3600)
	local minute = math.floor((timeOfDay - hour * 3600) / 60)
	local second = timeOfDay - hour * 3600 - minute * 60
	-- Days since 1970 requires subtracting the 693 years of ticks before it.
	local unixDays = days - 719162
	if unixDays < 0 then
		return string.format("%02d%02d%02d", hour, minute, second)
	end
	-- Civil-from-days (Howard Hinnant's algorithm) keeps this dependency free.
	local z = unixDays + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local year = yoe + era * 400
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local day = doy - math.floor((153 * mp + 2) / 5) + 1
	local month = if mp < 10 then mp + 3 else mp - 9
	-- The algorithm counts years from March, so January and February still belong to
	-- the previous year. Without this the stamp is a year early for the first two
	-- months of every year, which is exactly the kind of off-by-one that only shows
	-- up in January.
	if month <= 2 then
		year += 1
	end
	return string.format("%04d%02d%02d-%02d%02d%02d", year, month, day, hour, minute, second)
end

---- Paths ----------------------------------------------------------------------

-- Replay.listLoaded() and Replay.listAll() are known to report the same replay
-- with different shapes: one gives a bare name, the other a directory-qualified
-- path. Every comparison in this project goes through basename() first.
function Util.basename(path: string): string
	local name = path
	while true do
		local slash = string.find(name, "/", 1, true)
		if slash == nil then
			break
		end
		name = string.sub(name, slash + 1)
	end
	while true do
		local backslash = string.find(name, "\\", 1, true)
		if backslash == nil then
			break
		end
		name = string.sub(name, backslash + 1)
	end
	return name
end

function Util.hasReplayExtension(name: string): boolean
	local lower = string.lower(name)
	return string.sub(lower, -#".a2replay") == ".a2replay"
end

-- Strips directories and a trailing .a2replay, which is the form stored in
-- shot files so they keep working if the replays folder moves.
function Util.shortReplayName(path: string): string
	local name = Util.basename(path)
	if Util.hasReplayExtension(name) then
		name = string.sub(name, 1, -(#".a2replay" + 1))
	end
	return name
end

function Util.containsCaseless(haystack: string, needle: string): boolean
	if #needle == 0 then
		return true
	end
	return string.find(string.lower(haystack), string.lower(needle), 1, true) ~= nil
end

---- Errors ---------------------------------------------------------------------

-- Normalises whatever pcall produced into a printable string. Luau error values
-- can be tables or userdata, and an unhandled one of those prints as "table: 0x…".
function Util.errorText(raw: any): string
	if type(raw) == "string" then
		return raw :: string
	end
	local ok, described = pcall(tostring, raw)
	if ok and type(described) == "string" and #(described :: string) > 0 then
		return described :: string
	end
	return "unknown error"
end

-- Calls a function that may throw and returns (value, nil) or (nil, errorText).
-- Used around every Replay/LuauFile call so one bad file cannot stop the tick.
function Util.try(callable: () -> any): (any, string?)
	local ok, result = pcall(callable)
	if ok then
		return result, nil
	end
	return nil, Util.errorText(result)
end

-- Calls and reports, returning the value or nil plus a ready-made notice.
function Util.tryWith(action: string, callable: () -> any): (any, Notice?)
	local result, err = Util.try(callable)
	if err ~= nil then
		return nil, { kind = "error", text = action .. " failed: " .. err }
	end
	return result, nil
end

---- Collections ----------------------------------------------------------------

function Util.indexOf(list: { any }, value: any): number?
	for index, item in list do
		if item == value then
			return index
		end
	end
	return nil
end

function Util.length(list: { any }): number
	return #list
end

return Util
