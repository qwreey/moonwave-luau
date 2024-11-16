--!nocheck
--!native

local parser = require("./parser-lua")

function strip(str: string): string
	return string.gsub(string.gsub(str, "^\n+", ""), "\n+$", "")
end

--#region raw, read from file string
-- Parse --[=[(.*)]=] segment
-- RawFile => { "comment", ... }
local moonwave_raw = parser.createParser({
	parser.luaStrings(function()
		return
	end),
	-- Declare start
	"%-%-%[=%[[\n%s]-\n(%s*)",
	declare = parser.createParser({
		"%]=%]",
		parser.eof,
		orphans = function(self, str)
			self.content = str
		end,
	}),
	function(self, str, pos, startAt, endAt, indent)
		local parsed, declareEndAt = self:declare(str, endAt + 1)
		-- Remove indent
		local content = string.gsub(parsed.content, `\n{indent}([^\n]+)`, function(content)
			return content .. "\n"
		end)
		table.insert(self.comments, content)
		return declareEndAt + 1
	end,

	orphans = function() end,
	init = function(self)
		self.comments = {}
	end,
	stop = function(self)
		return self.comments
	end,
	noEOF = true,
})
export type moonwave_raw = { string }
--#endregion raw, read from file string

--#region low, block to element
-- Parse @tag and comments. one --[=[]=] => one element
local moonwave_parser = parser.createParser({
	-- Process escape
	"(\\.)",
	function(self, str, pos, startAt, endAt, char)
		table.insert(self.comments, char)
	end,
	-- Should be 'comments' content. ignore tagged annotations
	"```",
	codeInner = parser.createParser({
		"```",
		parser.eof,
		orphans = function(self, str)
			table.insert(self.parent.comments, str)
			table.insert(self.parent.comments, "```")
		end,
	}),
	function(self, str, pos, startAt, endAt)
		table.insert(self.comments, "```")
		local _, codeEndAt = self:codeInner(str, endAt + 1)
		return codeEndAt + 1
	end,
	"`",
	inlineInner = parser.createParser({
		-- Process escape
		"(\\.)",
		function(self, str, pos, startAt, endAt, char)
			table.insert(self.parent.comments, char)
		end,
		"`",
		parser.eof,
		orphans = function(self, str)
			table.insert(self.parent.comments, str)
		end,
		stop = function(self)
			table.insert(self.parent.comments, "`")
		end,
	}),
	function(self, str, pos, startAt, endAt)
		table.insert(self.comments, "`")
		local _, codeEndAt = self:inlineInner(str, endAt + 1)
		return codeEndAt + 1
	end,

	-- Tagged annotations
	"\n*%s*@(%a+) +([^\n]+)\n*",
	function(self, str, pos, startAt, endAt, tag, content)
		table.insert(self.tags, { tag = tag, content = content })
	end,

	orphans = function(self, str)
		table.insert(self.comments, str)
	end,
	init = function(self)
		self.comments = {}
		self.tags = {}
	end,
	stop = function(self)
		return {
			comments = strip(table.concat(self.comments)),
			tags = self.tags,
		}
	end,
	noEOF = true,
})
export type moonwave_low = {
	[number]: {
		comments: string,
		tags: { [number]: { tag: string, content: string } },
	},
}
local function moonwave_low(segments: moonwave_raw): moonwave_low
	local mapped = table.create(#segments)
	for index, raw in ipairs(segments) do
		mapped[index] = moonwave_parser(raw)
	end
	return mapped
end
--#endregion low, block to element

--#region middle, gather elements by within, specific element kind
export type moonwave_middle_kind =
	"method"
	| "function"
	| "interface"
	| "prop"
	| "field"
	| "type"
	| "unknown"
local moonwave_middle_kind_lookup = {
	"method",
	"function",
	"interface",
	"prop",
	"field",
	"type",
}
export type moonwave_middle_element = {
	kind: moonwave_middle_kind,
	comments: string,
	tags: { [number]: { tag: string, comments: string } },
}
export type moonwave_middle = {
	-- group with within
	[string]: {
		-- class it self
		self: moonwave_middle_element,
		[number]: moonwave_middle_element,
	},
}
local function moonwave_middle(low: moonwave_low): moonwave_middle
	return
end
--#endregion middle, gather elements by within, specific element kind

--#region high, handle all moonwave metadatas and export classes
export type moonwave_high_kind = moonwave_middle_kind
export type moonwave_high_base = {
	kind: moonwave_high_kind,
	name: string,
	comments: string,
	tag: { [number]: string },
	unused: { [number]: { tag: string, content: string } },
}
export type moonwave_high_usage = {
	unreleased: boolean,
	since: string | nil,
	deprecated: { version: string, description: string } | nil,
}
export type moonwave_high_field = {
	readonly: boolean,
} | moonwave_high_base | moonwave_high_usage
export type moonwave_high_type = {
	type: string,
} | moonwave_high_base | moonwave_high_usage
export type moonwave_high_unknown = moonwave_high_base | moonwave_high_usage
export type moonwave_high_function = {
	yields: boolean,

	-- <name> -- [desc]
	-- <name> [desc]
	-- `<name>` [desc]
	-- `<name>` -- [desc]
	params: { [number]: { name: string, description: string } },

	-- <type> -- [desc]
	-- <type> [desc]
	-- `<type>` [desc]
	-- `<type>` -- [desc]
	returns: { [number]: { type: string, description: string } },

	-- <type> -- [desc]
	-- <type> [desc]
	-- `<type>` [desc]
	-- `<type>` -- [desc]
	errors: { [number]: { type: string, description: string } },

	types: { [number]: moonwave_high_type },
} | moonwave_high_base | moonwave_high_usage
export type moonwave_high_class = {
	interfaces: { [number]: moonwave_high_interface },
	methods: { [number]: moonwave_high_function },
	functions: { [number]: moonwave_high_function },
	fields: { [number]: moonwave_high_field },
	props: { [number]: moonwave_high_field },
	unknowns: { [number]: moonwave_high_unknown },
} | moonwave_high_base | moonwave_high_usage
export type moonwave_high = { [string]: moonwave_class, [":ungrouped"]: moonwave_high_class }

local function moonwave_high() end
--#endregion high, handle all moonwave metadatas and export classes

local function parseString(content: string): moonwave_high
	local raw = moonwave_low(content)
	local middle = moonwave_middle(raw)
	local high = moonwave_high(middle)
	return high
end

return {
	parseString = parseString,
	moonwave_high = moonwave_high,
	moonwave_middle = moonwave_middle,
	moonwave_low = moonwave_low,
	moonwave_raw = moonwave_raw,
}
