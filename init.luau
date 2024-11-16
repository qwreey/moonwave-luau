--!nocheck
--!native

local parser = require("./parser-lua")

local function stripWhitespaces(str: string): string
	return string.gsub(string.gsub(str, "^%s+", ""), "%s+$", "")
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
			return "\n" .. content
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
	-- "[%s\n]*@(%a+) +([^\n]+)[%s\n]*",
	{"@(%a+) +([^\n]+)[\n \t]", "@(%a+) +([^\n]+)[\n \t]$"},
	function(self, str, pos, startAt, endAt, tag, content)
		table.insert(self.tags, { tag = tag, content = content })
	end,
	{"@(%a+)[\n \t]", "@(%a+)$"},
	function(self, str, pos, startAt, endAt, tag, content)
		table.insert(self.tags, { tag = tag, content = content })
	end,

	orphans = function(self, str)
		table.insert(self.comments, str)
	end,
	tailing = function(self, str)
		table.insert(self.comments, str)
	end,
	init = function(self)
		self.comments = {}
		self.tags = {}
	end,
	stop = function(self)
		return {
			comments = stripWhitespaces(table.concat(self.comments)),
			tags = self.tags,
		}
	end,
	noEOF = true,
})
export type moonwave_low_tag = { tag: string, content: string }
export type moonwave_low_tag_list = { [number]: moonwave_low_tag }
export type moonwave_low = {
	[number]: {
		comments: string,
		tags: moonwave_low_tag_list,
	},
}
local function moonwave_low(segments: moonwave_raw): moonwave_low
	local low = table.create(#segments) :: moonwave_low
	for index, raw in ipairs(segments) do
		low[index] = moonwave_parser(raw)
	end
	return low
end
local function moonwave_low_tag_find(tags: moonwave_low_tag_list, tag_name: string): moonwave_low_tag?
	for _, tag in ipairs(tags) do
		if tag.tag == tag_name then
			return tag
		end
	end
	return nil
end
-- local function moonwave_low_tag_iter(tags: moonwave_low_tag_list, tag_name: string): moonwave_low_tag?
-- 	local index = 0
-- 	return function ()
-- 		while true do
-- 			index += 1
-- 			local tag = tags[index]
-- 			if not tag then
-- 				return
-- 			end
-- 			if tag.tag == tag_name then
-- 				return tag
-- 			end
-- 		end
-- 	end
-- end
--#endregion low, block to element

--#region middle, gather elements by within, specific element kind
export type moonwave_middle_kind =
	"method"
	| "class"
	| "function"
	| "interface"
	| "prop"
	| "field"
	| "type"
	| "unknown"
local moonwave_middle_kind_lookup = {
	"class",
	"method",
	"function",
	"interface",
	"prop",
	"field",
	"type",
}
export type moonwave_middle_element = {
	kind: moonwave_middle_kind,
	within: string | ":ungrouped",
	comments: string,
	name: string,
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
local function moonwave_get_kind(tags: moonwave_low_tag_list): (moonwave_middle_kind, string)
	for _, kind in ipairs(moonwave_middle_kind_lookup) do
		local tag = moonwave_low_tag_find(tags, kind)
		if tag then return kind, stripWhitespaces(tag.content) end
	end
	return "unknown"
end
local function moonwave_middle_push(middle: moonwave_middle, element: moonwave_middle_element)
	local within = middle[element.within]
	if not within then
		within = {}
		middle[element.within] = within
	end
	if element.kind == "class" then
		if within.self then
			error(`@class {element.within} already defined`)
		end
		within.self = element
	else
		table.insert(within, element)
	end
end
local function moonwave_middle(low: moonwave_low): moonwave_middle
	local middle = {} :: moonwave_middle
	for _, element in ipairs(low) do
		local tags = element.tags
		local kind, name = moonwave_get_kind(tags)
		local within = moonwave_low_tag_find(tags, "within")
		moonwave_middle_push(middle, {
			name = name,
			within = if kind == "class" then name else (if within then stripWhitespaces(within.content) else ":ungrouped"),
			comments = element.comments,
			tags = tags,
			kind = kind,
		})
	end
	return middle
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
	since: string?,
	deprecated: { version: string, description: string }?,
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
	local raw = moonwave_raw(content)
	require("@lune/fs").writeFile("./raw-ignoreme", require("@lune/serde").encode("json", raw, true))
	local low = moonwave_low(raw)
	require("@lune/fs").writeFile("./low-ignoreme", require("@lune/serde").encode("json", low, true))
	local middle = moonwave_middle(low)
	require("@lune/fs").writeFile("./middle-ignoreme", require("@lune/serde").encode("json", middle, true))
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
