--!nocheck
--!native

-- TODO: external
-- TODO: source map (line info)
-- TODO: moonwave_high_interface

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
export type moonwave_middle_tag = { tag: string, comments: string }
export type moonwave_middle_tag_list = { [number]: moonwave_middle_tag }
export type moonwave_middle_element = {
	kind: moonwave_middle_kind,
	within: string | ":ungrouped",
	comments: string,
	name: string?,
	tags: moonwave_middle_tag_list,
}
export type moonwave_middle = {
	-- group with within
	[string]: {
		-- class it self
		self: moonwave_middle_element,
		[number]: moonwave_middle_element,
	},
	[":ungrouped"]: { [number]: moonwave_middle_element },
}
local function moonwave_middle_get_kind(tags: moonwave_low_tag_list): (moonwave_middle_kind, string)
	for _, kind in ipairs(moonwave_middle_kind_lookup) do
		local tag = moonwave_low_tag_find(tags, kind)
		if tag then return kind, stripWhitespaces(tag.content) end
	end
	return "unknown", nil
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
		local kind, name = moonwave_middle_get_kind(tags)
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
	within: string,
	name: string,
	comments: string,
	tags: { [number]: string }?,
	unused_tags: moonwave_middle_tag_list?,
	raw_tags: moonwave_middle_tag_list,
}
export type moonwave_high_usage = {
	unreleased: boolean,
	since: string?,
	deprecated: { version: string, description: string }?,
}
export type moonwave_high_realm = {
	server: boolean,
	client: boolean,
	plugin: boolean,
}
export type moonwave_high_visibility = {
	private: boolean,
	ignore: boolean,
}
export type moonwave_high_field = {
	readonly: boolean,

	types: { [number]: moonwave_high_type }?,
} & moonwave_high_base & moonwave_high_usage & moonwave_high_realm & moonwave_high_visibility
export type moonwave_high_type = {
	type: string,
	name: string,
}
export type moonwave_high_unknown = {
	kind: "unknown",
	within: string,
	comments: string,
	raw_tags: moonwave_middle_tag_list
}
export type moonwave_high_function_param = { name: string, type: string?, description: string? }
export type moonwave_high_function_return = { type: string, description: string? }
export type moonwave_high_function_error = { type: string, description: string? }
export type moonwave_high_function = {
	yields: boolean,

	-- <name> -- [desc]
	-- <name> [desc]
	-- `<name>` [desc]
	-- `<name>` -- [desc]
	params: { [number]: moonwave_high_function_param }?,

	-- <type> -- [desc]
	-- <type> [desc]
	-- `<type>` [desc]
	-- `<type>` -- [desc]
	returns: { [number]: moonwave_high_function_return }?,

	-- <type> -- [desc]
	-- <type> [desc]
	-- `<type>` [desc]
	-- `<type>` -- [desc]
	errors: { [number]: moonwave_high_function_error }?,

	types: { [number]: moonwave_high_type }?,
} & moonwave_high_base & moonwave_high_usage & moonwave_high_realm & moonwave_high_visibility
export type moonwave_high_class = {
	interfaces: { [number]: moonwave_high_interface }?,
	methods: { [number]: moonwave_high_function }?,
	functions: { [number]: moonwave_high_function }?,
	fields: { [number]: moonwave_high_field }?,
	props: { [number]: moonwave_high_field }?,
	unknowns: { [number]: moonwave_high_unknown }?,
	types: { [number]: moonwave_high_type }?,
} & moonwave_high_base & moonwave_high_usage & moonwave_high_realm & moonwave_high_visibility
export type moonwave_high = { [string]: moonwave_class, [":ungrouped"]: moonwave_high_class }
export type moonwave_high_item = moonwave_high_interface | moonwave_high_function | moonwave_high_field | moonwave_high_unknown

local function moonwave_high_list_push(
	moonwave_class_list: moonwave_high, item: moonwave_high_item
)
	local kind = (item :: moonwave_high_base).kind
	local within = (item :: moonwave_high_base).within
	local class = moonwave_class_list[within]

	if not class then
		class = {}
		moonwave_class_list[within] = class
	end

	if kind == "class" then
		for key, value in pairs(item :: moonwave_high_class) do
			class[key] = value
		end
		return
	end

	local list = class[kind.."s"]
	if not list then
		list = {}
		class[kind.."s"] = list
	end

	table.insert(list, item)
end
local function get_or_create_table<T>(item: T&{}, key: string): { any }
	local t = item[key]
	if t then
		return t
	end
	t = {}
	item[key] = t
	return t
end
local function set_or_concat_string(item: { any }, key: string, content: string)
	local str = item[key]
	if str then
		item[key] = `{str}\n{content}`
	else
		item[key] = content
	end
end
local function parse_dashed_content(dashed_comments: string): (string?, string?)
	local head, body = string.match(dashed_comments, "^(.-)[\t ]+%-%-[\t ]+(.+)$")
	if head then
		return  head, body
	end

	-- with ""
	local first_char = string.sub(dashed_comments, 1, 1)
	if first_char == "[" or first_char == "'" or first_char == "\"" then
		local passed, err, endAt = pcall(parser.luaStringParser(dashed_comments))
		if not passed then
			error("lua string parsing failed. "..err)
		end
		return string.sub(dashed_comments, 1, endAt), stripWhitespaces(string.sub(dashed_comments, endAt+1, -1))
	end

	head, body = string.match(dashed_comments, "^([^ \t]+) +(.+)$")
	if head then
		return head, body
	end
	return nil, nil
end
-- handle tag tag
local function moonwave_high_handle_base(item: moonwave_high_base, tag: moonwave_middle_tag): boolean
	if tag.tag == "tag" then
		table.insert(
			get_or_create_table(item, "tags"),
			tag.comments
		)
		return true
	end

	return false
end
-- handle unreleased, deprecated, since tag
local function moonwave_high_handle_usage(item: moonwave_high_usage, tag: moonwave_middle_tag?): boolean
	-- default value
	if not tag then
		item.unreleased = false
		return false
	end

	-- unreleased
	if tag.tag == "unreleased" then
		item.unreleased = true
		return true
	end

	-- deprecated
	if tag.tag == "deprecated" then
		if item.deprecated then
			item.deprecated.body = `{item.deprecated.body}\n{tag.comments}`
		else
			local head, body = parse_dashed_content(tag.comments)
			item.deprecated = {
				head = head or "",
				body = body or tag.comments,
			}
		end
		return true
	end

	-- since
	if tag.tag == "since" then
		set_or_concat_string(item, "since", tag.comments)
		return true
	end

	return false
end
-- handle client, server, plugin tag
local function moonwave_high_handle_realm(item: moonwave_high_realm, tag: moonwave_middle_tag?): boolean
	-- default value
	if not tag then
		item.client = false
		item.server = false
		item.plugin = false
		return false
	end

	if tag.tag == "server" then
		item.server = true
		return true
	elseif tag.tag == "client" then
		item.client = true
		return true
	elseif tag.tag == "plugin" then
		item.plugin = true
		return true
	end

	return false
end
-- handle ignore, private tag
local function moonwave_high_handle_visibility(item: moonwave_high_visibility, tag: moonwave_middle_tag?): boolean
	-- default
	if not tag then
		item.ignore = false
		item.private = false
		return false
	end

	if tag.tag == "private" then
		item.private = true
		return true
	elseif tag.tag == "ignore" then
		item.ignore = true
		return true
	end

	return false
end
-- handle readonly tag
local function moonwave_high_handle_field(item: moonwave_high_field, tag: moonwave_middle_tag?): boolean
	if not tag then
		item.readonly = false
		return false
	end

	if tag.tag == "readonly" then
		item.readonly = true
		return true
	end

	return false
end
-- handle param, return, error tag
local function moonwave_high_handle_function(item: moonwave_high_function, tag: moonwave_middle_tag?): boolean
	-- default
	if not tag then
		item.yields = false
		return false
	end

	if tag.tag == "yields" then
		item.yields = true
		return true
	end

	if tag.tag == "param" then
		local name, tailing = string.match(tag.contents, "^([^ \t]+)[\t ]+(.+)$")
		if not name then
			error("unexpect line: " .. tag.contents)
		end
		local head, body = parse_dashed_content(tailing)
		local param = {
			name = name,
		} :: moonwave_high_function_param
		if head then
			param.type = head
			param.description = body
		elseif tailing ~= "" then
			param.description = tailing
		end
		table.insert(
			get_or_create_table(item, "params"),
			param
		)
		return true
	end

	if tag.tag == "return" then
		local return_ = {} :: moonwave_high_function_return
		local head, body = parse_dashed_content(tag.contents)
		if head then
			return_.type = head
			return_.description = body
		else
			if tag.comments == "" then
				error("missing content on reutrn")
			end
			return_.type = tag.comments
		end
		table.insert(
			get_or_create_table(item, "returns"),
			return_
		)
		return true
	end

	if tag.tag == "error" then
		local head, body = parse_dashed_content(tag.contents)
		local error_ = {} :: moonwave_high_function_error
		if head then
			error_.type = head
			error_.description = body
		else
			if tag.comments == "" then
				error("missing content on error")
			end
			error_.type = tag.comments
		end
		table.insert(
			get_or_create_table(item, "errors"),
			error_
		)
		return true
	end

	return false
end
-- handle type tag
local function moonwave_high_handle_type(item: { 
	types: { [number]: moonwave_high_type }?
}, tag: moonwave_middle_tag): boolean
	if tag.tag == "type" then
		local name, type_ = string.match(tag.comments, "^([^ \t]+)[ \t]+$")
		if not name then
			error("missing content on type")
		end
		table.insert(
			get_or_create_table(item, "types"),
			{ name = name, type = type_ } :: moonwave_high_type
		)
		return true
	end

	return false
end
-- handle middle element (to high item)
local function moonwave_high_handle_element(element: moonwave_middle_element): moonwave_high_item
	local base = {
		comments = element.comments,
		within = element.within,
		name = element.name,
		kind = element.kind,
		raw_tags = element.tags,
	} :: moonwave_high_base | moonwave_high_unknown

	local kind = element.kind :: moonwave_middle_kind
	if kind == "unknown" then
		return base
	end

	local isField = kind == "prop" or kind == "field"
	local isFunction = (kind == "function" or kind == "method")
	local isInterface = kind == "interface"
	local isClass = kind == "class"
	local hasTypes = isField or isFunction or isInterface or isClass

	moonwave_high_handle_usage(base :: moonwave_high_usage)
	moonwave_high_handle_realm(base :: moonwave_high_realm)
	moonwave_high_handle_visibility(base :: moonwave_high_visibility)
	if isField then
		moonwave_high_handle_field(base :: moonwave_high_field)
	end
	if isFunction then
		moonwave_high_handle_function(base :: moonwave_high_field)
	end

	local unused_tags = {}
	for _,tag in ipairs(element.tags) do
		if kind ~= "unknown" and (
			moonwave_high_handle_base(base :: moonwave_high_base, tag)
			or moonwave_high_handle_usage(base :: moonwave_high_usage, tag)
			or moonwave_high_handle_realm(base :: moonwave_high_realm, tag)
			or moonwave_high_handle_visibility(base :: moonwave_high_visibility, tag)
		) then
		elseif isField and moonwave_high_handle_field(base :: moonwave_high_field) then
		elseif isFunction and moonwave_high_handle_function(base :: moonwave_high_function) then
		elseif hasTypes and moonwave_high_handle_type(base :: any, tag) then
		else
			-- unprocessed tag
			table.insert(unused_tags, tag)
		end
	end

	if #unused_tags ~= 0 then
		base.unused_tags = unused_tags
	end

	return base
end
local function moonwave_high(middle: moonwave_middle): moonwave_high
	local high = { [":ungrouped"] = {} } :: moonwave_high

	for within, items in pairs(middle) do
		if items.self then
			moonwave_high_list_push(high, moonwave_high_handle_element(items.self))
		end
		for _,item in ipairs(items) do
			moonwave_high_list_push(high, moonwave_high_handle_element(item))
		end
	end

	return high
end
--#endregion high, handle all moonwave metadatas and export classes

local function parseString(content: string): moonwave_high
	local raw = moonwave_raw(content)
	local low = moonwave_low(raw)
	local middle = moonwave_middle(low)
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
