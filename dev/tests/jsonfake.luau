--!strict
--[[
	A deliberately small JSON codec, used only by the tests.

	shotfile.luau takes its JSON implementation as an injected pair, because the
	client supplies LuauJson at runtime and the reference `luau` CLI has no JSON
	library at all. So the tests need one, and it has to be a real codec: a shot
	file is only worth testing if encode and decode are genuinely inverses.

	It is not a general-purpose library. It handles the JSON that shotfile produces
	- tables, strings, finite numbers, booleans, null - and nothing else.
]]

local Json = {}

local function isSequence(value: { any }): boolean
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" then
			return false
		end
		count += 1
	end
	-- Every index from 1 to n has to be present, so a sparse table is encoded as an
	-- object rather than silently losing entries.
	if count == 0 then
		return true
	end
	for index = 1, count do
		if value[index] == nil then
			return false
		end
	end
	return true
end

local function encodeValue(value: any): string
	local kind = type(value)
	if value == nil then
		return "null"
	elseif kind == "boolean" then
		return if value :: boolean then "true" else "false"
	elseif kind == "number" then
		local number = value :: number
		if number ~= number or number == math.huge or number == -math.huge then
			-- Not representable in JSON; the encoder in shotfile never produces
			-- these, and the tests must not silently invent one.
			error("cannot encode non-finite number", 0)
		end
		if math.floor(number) == number and math.abs(number) < 1e15 then
			return string.format("%.0f", number)
		end
		return string.format("%.14g", number)
	elseif kind == "string" then
		return string.format("%q", value :: string)
	elseif kind == "table" then
		local list = value :: { any }
		local parts: { string } = {}
		if isSequence(list) then
			for _, entry in list do
				table.insert(parts, encodeValue(entry))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for key, entry in pairs(list) do
			if type(key) == "string" and entry ~= nil then
				table.insert(parts, string.format("%q", key) .. ":" .. encodeValue(entry))
			end
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("cannot encode a value of type " .. kind, 0)
end

function Json.serialize(value: any, _pretty: boolean): string
	return encodeValue(value)
end

---- Parsing -------------------------------------------------------------------

local function skipSpace(text: string, at: number): number
	local index = at
	while index <= #text do
		local character = string.sub(text, index, index)
		if character ~= " " and character ~= "\t" and character ~= "\n" and character ~= "\r" then
			return index
		end
		index += 1
	end
	return index
end

-- Forward declaration so the container parsers can call back into it.
local parseValue: (string, number) -> (any, number)

local function parseString(text: string, at: number): (string, number)
	local index = at + 1
	local buffer: { string } = {}
	while index <= #text do
		local character = string.sub(text, index, index)
		if character == '"' then
			return table.concat(buffer), index + 1
		elseif character == "\\" then
			local escaped = string.sub(text, index + 1, index + 1)
			if escaped == "n" then
				table.insert(buffer, "\n")
			elseif escaped == "t" then
				table.insert(buffer, "\t")
			elseif escaped == "r" then
				table.insert(buffer, "\r")
			elseif escaped == "b" then
				table.insert(buffer, "\b")
			elseif escaped == "f" then
				table.insert(buffer, "\f")
			elseif escaped == "u" then
				-- Only the escapes this codec itself produces are supported.
				table.insert(buffer, "?")
			else
				table.insert(buffer, escaped)
			end
			index += 2
		else
			table.insert(buffer, character)
			index += 1
		end
	end
	error("unterminated string", 0)
end

local function parseNumber(text: string, at: number): (number, number)
	local index = at
	while index <= #text do
		local character = string.sub(text, index, index)
		if string.find(character, "^[%d%+%.eE%-]$") == nil then
			break
		end
		index += 1
	end
	local raw = string.sub(text, at, index - 1)
	local number = tonumber(raw)
	if number == nil then
		error("bad number " .. raw, 0)
	end
	return number, index
end

local function parseWord(text: string, at: number): (any, number)
	if string.sub(text, at, at + 3) == "true" then
		return true, at + 4
	elseif string.sub(text, at, at + 4) == "false" then
		return false, at + 5
	elseif string.sub(text, at, at + 3) == "null" then
		return nil, at + 4
	end
	error("unexpected token at " .. tostring(at), 0)
end

parseValue = function(text: string, at: number): (any, number)
	local index = skipSpace(text, at)
	local character = string.sub(text, index, index)
	if character == "" then
		error("unexpected end of input", 0)
	elseif character == '"' then
		return parseString(text, index)
	elseif character == "[" then
		local list: { any } = {}
		index = skipSpace(text, index + 1)
		if string.sub(text, index, index) == "]" then
			return list, index + 1
		end
		while true do
			local value
			value, index = parseValue(text, index)
			table.insert(list, value)
			index = skipSpace(text, index)
			local delimiter = string.sub(text, index, index)
			if delimiter == "]" then
				return list, index + 1
			elseif delimiter ~= "," then
				error("expected , or ] at " .. tostring(index), 0)
			end
			index += 1
		end
	elseif character == "{" then
		local object: { [string]: any } = {}
		index = skipSpace(text, index + 1)
		if string.sub(text, index, index) == "}" then
			return object, index + 1
		end
		while true do
			local key
			key, index = parseString(text, skipSpace(text, index))
			index = skipSpace(text, index)
			if string.sub(text, index, index) ~= ":" then
				error("expected : at " .. tostring(index), 0)
			end
			local value
			value, index = parseValue(text, index + 1)
			object[key] = value
			index = skipSpace(text, index)
			local delimiter = string.sub(text, index, index)
			if delimiter == "}" then
				return object, index + 1
			elseif delimiter ~= "," then
				error("expected , or } at " .. tostring(index), 0)
			end
			index += 1
		end
	elseif character == "-" or string.find(character, "^%d$") ~= nil then
		return parseNumber(text, index)
	end
	return parseWord(text, index)
end

function Json.parse(text: string): any
	if type(text) ~= "string" or #text == 0 then
		error("empty input", 0)
	end
	local value, index = parseValue(text, 1)
	if skipSpace(text, index) <= #text then
		error("trailing content", 0)
	end
	return value
end

return Json
