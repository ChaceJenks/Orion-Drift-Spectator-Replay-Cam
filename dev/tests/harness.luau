--!strict
--[[
	Minimal test harness.

	Deliberately not a framework: the tests run under the reference `luau` CLI,
	which has no test runner, and the whole point of running them is to catch
	regressions in the pure logic without launching the game client.
]]

local Harness = {}

local failures: { string } = {}
local currentSuite = "unset"
local checks = 0

function Harness.suite(name: string)
	currentSuite = name
end

local function fail(message: string)
	table.insert(failures, currentSuite .. ": " .. message)
end

function Harness.check(condition: any, message: string)
	checks += 1
	if not condition then
		fail(message)
	end
end

function Harness.equal(actual: any, expected: any, message: string)
	checks += 1
	if actual ~= expected then
		fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
	end
end

-- Compares with a tolerance so the maths tests do not depend on float noise.
function Harness.near(actual: number, expected: number, message: string, tolerance: number?)
	checks += 1
	local allowed = tolerance or 1e-6
	if not (type(actual) == "number" and type(expected) == "number") then
		fail(message .. " (non-numeric input)")
		return
	end
	local delta = math.abs(actual - expected)
	if delta > allowed or actual ~= actual then
		fail(string.format("%s (expected %.9g +/- %g, got %.9g)", message, expected, allowed, actual))
	end
end

function Harness.isNil(value: any, message: string)
	checks += 1
	if value ~= nil then
		fail(message .. " (expected nil, got " .. tostring(value) .. ")")
	end
end

function Harness.notNil(value: any, message: string)
	checks += 1
	if value == nil then
		fail(message .. " (unexpected nil)")
	end
end

function Harness.report(): number
	local failed = #failures
	local suiteName = currentSuite
	if failed == 0 then
		print(string.format("PASS  %s: %d checks, 0 failures", suiteName, checks))
	else
		print(string.format("FAIL  %s: %d checks, %d failures", suiteName, checks, failed))
		for _, message in failures do
			print("  - " .. message)
		end
	end
	-- Reset so each test file reports its own tally; the module is cached and
	-- therefore shared across every file the runner requires.
	failures = {}
	checks = 0
	return failed
end

function Harness.checkCount(): number
	return checks
end

return Harness
