--!nocheck
--!native

-- TODO: external
-- TODO: moonwave_high_interface

local parser = require("./parser-lua")

local function errline(line: number): string
	return `[line: {line}]`
end
local function stripWhitespaces(str: string): string
	return string.gsub(string.gsub(str, "^%s+", ""), "%s+$", "")
end
local function get_or_create_table<T>(item: T & {}, key: string): { any }
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

--#region raw, read from file string
-- Parse --[=[(.*)]=] segment
-- RawFile => { "comment", ... }
local moonwave_raw = parser.createParser({
	parser.luaStrings(function()
		return
	end),
	-- Declare start
	"%-%-%[=%[([\n%s]-\n)(%s*)",
	declare = parser.createParser({
		"%]=%]",
		parser.eof,
		orphans = function(self, str)
			self.content = str
		end,
	}),
	function(self, str, pos, startAt, endAt, newlines, indent)
		self.checkunder = true
		self:process_comment_buffer()
		local parsed, declareEndAt = self:declare(str, endAt + 1)

		-- count newlines
		for _ in string.gmatch(newlines, "\n") do
			self.line += 1
		end

		-- Remove indent
		local content = string.gsub(parsed.content, `\n{indent}([^\n]+)`, function(line)
			return "\n" .. line
		end)

		local linenums = {}
		local last = 1
		for endpos in string.gmatch(content, "()\n") do
			table.insert(linenums, self.line)
			self.line += 1
			last = endpos + 1
		end
		local content_len = #content
		if content_len > last then
			-- need test (  adsf]=]  ) like this no linebreak in ending
			table.insert(linenums, self.line)
		end

		table.insert(self.comments, { linenums = linenums, comments = content })
		return declareEndAt + 1
	end,

	{ "%-%-%-[\t ]*([^\n]+\n)", "%-%-%-[\t ]*([^\n]+)$" },
	function(self, str, pos, startAt, endAt, comment)
		self.checkunder = true
		table.insert(get_or_create_table(self, "buffer_comments"), comment)
		table.insert(get_or_create_table(self, "buffer_lines"), self.line)
		self.line += 1
	end,

	"[\t ]*\n",
	function(self)
		self.line += 1
	end,

	process_comment_buffer = function(self)
		local buffer_comments = self.buffer_comments
		if not buffer_comments then
			return
		end
		table.insert(self.comments, {
			linenums = self.buffer_lines,
			comments = table.concat(buffer_comments),
		})
		self.buffer_lines = nil
		self.buffer_comments = nil
	end,
	under_parser = parser.createParser({
		"^[ \t]*local[ \t]+([_%a][_%w]*)[ \t]+=[ \t]+function",
		function(self, str, pos, startAt, endAt, name)
			self.method = false
			self.name = name
			return endAt + 1, true
		end,
		{
			"^[ \t]*local[ \t]+function[ \t]+",
			"^[ \t]*function[ \t]+",
		},
		function(self, str, pos, startAt, endAt)
			local result, resultEndAt = self:function_parser(str, endAt + 1)
			self.result = result
			return resultEndAt + 1, true
		end,
		function_parser = parser.createParser({
			"([_%a][_%w]*)",
			function(self, str, pos, startAt, endAt, name)
				if not self.indexed then
					error(`{errline(self.parent.parent.line)} malformed function define`)
				end
				self.indexed = false
				self.parent.name = name
			end,
			"\t ",
			parser.ignore,
			"%.",
			function(self)
				if self.parent.method then
					error(`{errline(self.parent.parent.line)} malformed function define`)
				end
				self.indexed = true
			end,
			":",
			function(self)
				if self.parent.method then
					error("malformed function define")
				end
				self.parent.method = true
				self.indexed = true
			end,
			"[%(<]",
			parser.eof,
			init = function(self)
				self.indexed = true
				self.parent.method = false
			end,
			stop = function(self)
				if self.indexed then
					error(`{errline(self.parent.parent.line)} malformed function define`)
				end
			end,
			tailing = function() end,
			orphans = function() end,
		}),
		noEOF = true,
	}),
	orphans = function(self, under)
		self:process_comment_buffer()
		if self.checkunder then
			local result = self:under_parser(under)
			if result.name then
				self.comments[#self.comments].func = {
					name = result.name,
					method = result.method,
				}
			end
		end
		self.checkunder = false
	end,
	init = function(self)
		self.line = 1
		self.checkunder = false
		self.comments = {}
	end,
	stop = function(self)
		self:process_comment_buffer()
		return self.comments
	end,
	noEOF = true,
})
export type moonwave_raw_func = { name: string, method: boolean }
export type moonwave_raw = { [number]: { comments: string, linenums: { number }, func: moonwave_raw_func? } }
--#endregion raw, read from file string

--#region low, block to element
-- Parse @tag and comments. one --[=[]=] => one element
local moonwave_parser = parser.createParser({
	"\n",
	function(self)
		self.line += 1
		table.insert(self.comments, "\n")
	end,

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
		"\n",
		function(self)
			table.insert(self.parent.comments, "\n")
			self.parent.line += 1
		end,
		orphans = function(self, str)
			table.insert(self.parent.comments, str)
		end,
		stop = function(self)
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
		"\n",
		function(self)
			table.insert(self.parent.comments, "\n")
			self.parent.line += 1
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
	{ "@(%a+) +([^\n]+\n)", "@(%a+) +([^\n]+)$" },
	function(self, str, pos, startAt, endAt, tag, content)
		table.insert(self.tags, { tag = tag, content = content, line = self.linemaps[self.line] })
		self.line += 1
	end,
	{ "@(%a+)([\n \t])", "@(%a+)$" },
	function(self, str, pos, startAt, endAt, tag, tailing)
		table.insert(self.tags, { tag = tag, line = self.linemaps[self.line] })
		if tailing == "\n" then
			self.line += 1
		end
	end,

	orphans = function(self, str)
		table.insert(self.comments, str)
	end,
	tailing = function(self, str)
		table.insert(self.comments, str)
	end,
	init = function(self, _str, _pos, linemaps)
		self.comments = {}
		self.tags = {}
		self.line = 1
		self.linemaps = linemaps
	end,
	stop = function(self)
		return {
			comments = stripWhitespaces(table.concat(self.comments)),
			tags = self.tags,
			first_line = self.linemaps[1],
			end_line = self.linemaps[self.line - 1],
		}
	end,
	noEOF = true,
})
export type moonwave_low_tag = { line: number, tag: string, content: string }
export type moonwave_low_tag_list = { [number]: moonwave_low_tag }
export type moonwave_low_element = {
	first_line: number,
	comments: string,
	tags: moonwave_low_tag_list,
	func: moonwave_raw_func,
}
export type moonwave_low = { [number]: moonwave_low_element }
local function moonwave_low(segments: moonwave_raw): moonwave_low
	local low = table.create(#segments) :: moonwave_low
	for index, raw in ipairs(segments) do
		local element = moonwave_parser(raw.comments, 1, raw.linenums)
		element.func = raw.func
		low[index] = element
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
export type moonwave_middle_kind = "method" | "class" | "function" | "interface" | "prop" | "field" | "type" | "unknown"
local moonwave_middle_kind_lookup = {
	"class",
	"method",
	"function",
	"interface",
	"prop",
	"field",
	"type",
}
export type moonwave_middle_tag = { tag: string, comments: string, line: number }
export type moonwave_middle_tag_list = { [number]: moonwave_middle_tag }
export type moonwave_middle_element = {
	kind: moonwave_middle_kind,
	within: string | ":ungrouped",
	comments: string,
	name: string?,
	tags: moonwave_middle_tag_list,
	line: number,
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
local function moonwave_middle_get_kind(element: moonwave_low_element): (moonwave_middle_kind, string)
	local tags = element.tags
	for _, kind in ipairs(moonwave_middle_kind_lookup) do
		local tag = moonwave_low_tag_find(tags, kind)
		if tag then
			return kind, stripWhitespaces(tag.content)
		end
	end
	local func = element.func
	if func then
		return if func.method then "method" else "function", func.name
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
		local kind, name = moonwave_middle_get_kind(element)
		local within = moonwave_low_tag_find(tags, "within")
		moonwave_middle_push(middle, {
			name = name,
			within = if kind == "class"
				then name
				else (if within then stripWhitespaces(within.content) else ":ungrouped"),
			comments = element.comments,
			tags = tags,
			kind = kind,
			line = element.first_line,
		})
	end
	return middle
end
--#endregion middle, gather elements by within, specific element kind

--#region high, handle all moonwave metadatas and export classes
export type moonwave_high_kind = moonwave_middle_kind
export type moonwave_high_base = {
	kind: moonwave_high_kind,
	line: number,
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

	type: string?,

	types: { [number]: moonwave_high_type }?,
} & moonwave_high_base & moonwave_high_usage & moonwave_high_realm & moonwave_high_visibility
export type moonwave_high_type = {
	type: string,
	name: string,
	line: number,
}
export type moonwave_high_unknown = {
	kind: "unknown",
	line: number,
	within: string,
	comments: string,
	raw_tags: moonwave_middle_tag_list,
}
export type moonwave_high_function_param = { name: string, type: string?, description: string?, line: number }
export type moonwave_high_function_return = { type: string, description: string?, line: number }
export type moonwave_high_function_error = { type: string, description: string?, line: number }
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
export type moonwave_high = { [string]: moonwave_high_class, [":ungrouped"]: moonwave_high_class }
export type moonwave_high_item =
	moonwave_high_interface
	| moonwave_high_function
	| moonwave_high_field
	| moonwave_high_unknown

local function moonwave_high_list_push(moonwave_class_list: moonwave_high, item: moonwave_high_item)
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

	local list = class[kind .. "s"]
	if not list then
		list = {}
		class[kind .. "s"] = list
	end

	table.insert(list, item)
end
local function parse_dashed_content(dashed_comments: string, line: number): (string?, string?, boolean?)
	local head, body = string.match(dashed_comments, "^(.-)[\t ]+%-%-[\t ]+(.+)$")
	if head then
		return head, body, true
	end

	-- with ""
	local first_char = string.sub(dashed_comments, 1, 1)
	if first_char == "[" or first_char == "'" or first_char == '"' then
		local passed, err, endAt = pcall(parser.luaStringParser(dashed_comments))
		if not passed then
			error(`{errline(line)} lua string parsing failed. {err}`)
		end
		return string.sub(dashed_comments, 1, endAt), stripWhitespaces(string.sub(dashed_comments, endAt + 1, -1)), true
	end

	head, body = string.match(dashed_comments, "^([^ \t]+) +(.+)$")
	if head then
		return head, body, false
	end
	return nil, nil, nil
end
-- handle tag tag
local function moonwave_high_handle_base(item: moonwave_high_base, tag: moonwave_middle_tag): boolean
	if tag.tag == "tag" then
		table.insert(get_or_create_table(item, "tags"), tag.content)
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
			item.deprecated.body = `{item.deprecated.body}\n{tag.content}`
		else
			local head, body = parse_dashed_content(tag.content, tag.line)
			item.deprecated = {
				head = head or "",
				body = body or tag.content,
			}
		end
		return true
	end

	-- since
	if tag.tag == "since" then
		set_or_concat_string(item, "since", tag.content)
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
		local name, type_ = string.match(item.name, "^([^ \t]+)[ \t]+(.+)$")
		if name then
			item.name = name
			item.type = type_
		end
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
		local name, tailing = string.match(tag.content, "^([^ \t]+)[\t ]+(.+)$")
		if not name then
			error(`{errline(tag.line)} unexpect param content: {tag.content}`)
		end
		local head, body, dashed = parse_dashed_content(tailing, tag.line)
		local param = {
			name = name,
			line = tag.line,
		} :: moonwave_high_function_param
		if head and dashed then
			param.type = head
			param.description = body
		elseif tailing ~= "" then
			param.description = tailing
		end
		table.insert(get_or_create_table(item, "params"), param)
		return true
	end

	if tag.tag == "return" then
		local return_ = { line = tag.line } :: moonwave_high_function_return
		local head, body, dashed = parse_dashed_content(tag.content, tag.line)
		if head and dashed then
			return_.type = head
			return_.description = body
		else
			if tag.content == "" then
				error(`{errline(tag.line)} missing content on reutrn`)
			end
			return_.description = tag.content
		end
		table.insert(get_or_create_table(item, "returns"), return_)
		return true
	end

	if tag.tag == "error" then
		local head, body = parse_dashed_content(tag.content, tag.line)
		local error_ = { line = tag.line } :: moonwave_high_function_error
		if head then
			error_.type = head
			error_.description = body
		else
			if tag.content == "" then
				error(`{errline(tag.line)} missing content on error`)
			end
			error_.type = tag.content
		end
		table.insert(get_or_create_table(item, "errors"), error_)
		return true
	end

	return false
end
-- handle type tag
local function moonwave_high_handle_type(
	item: {
		types: { [number]: moonwave_high_type }?,
	},
	tag: moonwave_middle_tag
): boolean
	if tag.tag == "type" then
		local name, type_ = string.match(tag.content, "^([^ \t]+)[ \t]+$")
		if not name then
			error(`{errline(tag.line)} missing content on type`)
		end
		table.insert(
			get_or_create_table(item, "types"),
			{ name = name, type = type_, line = tag.line } :: moonwave_high_type
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
		line = element.line,
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
	for _, tag in ipairs(element.tags) do
		if
			kind ~= "unknown"
			and (
				moonwave_high_handle_base(base :: moonwave_high_base, tag)
				or moonwave_high_handle_usage(base :: moonwave_high_usage, tag)
				or moonwave_high_handle_realm(base :: moonwave_high_realm, tag)
				or moonwave_high_handle_visibility(base :: moonwave_high_visibility, tag)
			)
		then
		elseif isField and moonwave_high_handle_field(base :: moonwave_high_field, tag) then
		elseif isFunction and moonwave_high_handle_function(base :: moonwave_high_function, tag) then
		elseif hasTypes and moonwave_high_handle_type(base :: any, tag) then
		elseif
			tag.tag == "within"
			or tag.tag == "class"
			or tag.tag == "method"
			or tag.tag == "function"
			or tag.tag == "interface"
			or tag.tag == "prop"
			or tag.tag == "field"
			or tag.tag == "type"
		then
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

	for _, items in pairs(middle) do
		if items.self then
			moonwave_high_list_push(high, moonwave_high_handle_element(items.self))
		end
		for _, item in ipairs(items) do
			moonwave_high_list_push(high, moonwave_high_handle_element(item))
		end
	end

	return high
end
--#endregion high, handle all moonwave metadatas and export classes

--#region compat
-- export type Source = {
-- 	path: string,
-- 	line: number,
-- }

-- export type FunctionParam = {
-- 	name: string,
-- 	desc: string,
-- 	lua_type: string,
-- }

-- export type FunctionReturn = {
-- 	desc: string,
-- 	lua_type: string,
-- }

-- export type Function = {
-- 	name: string,
-- 	desc: string,
-- 	params: { FunctionParam },
-- 	returns: { FunctionReturn },
-- 	function_type: string,
-- 	tags: { string }?,
-- 	source: Source,
-- }

-- export type Property = {
-- 	name: string,
-- 	desc: string,
-- 	lua_type: string,
-- 	tags: { string }?,
-- 	source: Source,
-- }

-- export type Type = {
-- 	name: string,
-- 	desc: string,
-- 	source: Source,
-- }

-- export type Item = {
-- 	name: string,
-- 	desc: string,
-- 	functions: { Function },
-- 	properties: { Property },
-- 	types: { Type },
-- 	source: Source,
-- }

-- local function highToCompat(): { Item }

-- end
--#endregion

--#region docgen, compat with lune docgen
local docgen = {}
docgen.__index = docgen

function docgen.new()
	return setmetatable({ "<!-- markdownlint-disable -->\n\n" }, docgen)
end

function docgen:push(str: string): docgen
	table.insert(self, str)
	return self
end

function docgen:finalize(): string
	return string.gsub(table.concat(self), "\n+$", "") .. "\n"
end

function docgen:pushTitle(str: string, level: number?): docgen
	self:push(`{string.rep("#", level or 1)} {str}\n\n`)
	return self
end

function docgen:pushHr(): docgen
	self:push("\n---\n\n")
	return self
end

function docgen.inline(str: string): string
	return `\`{string.gsub(str, "`", "\\`")}\``
end

function docgen.strip(str: string): string
	return string.gsub(string.gsub(str, "^\n+", ""), "\n+$", "")
end

function docgen.indent(str: string, indent: string): string
	return `{indent}{string.gsub(str, "\n", `\n{indent}`)}`
end

function docgen:pushAttrs(item: moonwave_high_field | moonwave_high_function | moonwave_high_class): docgen
	local pushed = false

	-- unreleased tag
	if item.unreleased then
		self:push("**@unreleased**\n")
		pushed = true
	end

	-- readonly tag
	if (item :: moonwave_high_field).readonly then
		self:push("**@readonly**\n")
		pushed = true
	end

	-- since tag
	local since = item.since
	if since then
		self:push(`**@since** {docgen.strip(since)}\n`)
		pushed = true
	end

	-- deprecated
	local deprecated = item.deprecated
	if deprecated then
		self:push(
			`**@deprecated** {docgen.inline(docgen.strip(deprecated.version))} {docgen.strip(deprecated.description)}\n`
		)
		pushed = true
	end

	if item.tags then
		for _, tag in item.tags do
			if tag == "must_use\n" then
				self:push("**@must_use**\n")
				pushed = true
			end
		end
	end

	if pushed then
		self:push("\n")
	end

	return self
end

-- Push properties
function docgen:pushProps(props: { moonwave_high_field }, _titleIndent: number?, noTitle: boolean?): docgen
	if #props == 0 then
		return
	end
	local titleIndent = _titleIndent or 2
	if not noTitle then
		self:pushTitle("Properties", titleIndent)
	end
	for index, item in props do
		if item.ignore then
			continue
		end

		-- name
		self:pushTitle(docgen.strip(item.name), titleIndent + 1)

		-- attrs
		self:pushAttrs(item)

		-- inline type
		if item.type then
			self:push(`{docgen.inline(docgen.strip(item.type))}\n\n`)
		end

		-- comments
		if item.comments ~= "" then
			self:push(`{docgen.strip(item.comments)}\n`)
		end

		-- hr
		if props[index + 1] then
			self:pushHr()
		end
	end
	self:push("\n")
	return self
end

function docgen:pushFields(fields: { moonwave_high_field }, titleIndent: number?, noTitle: boolean?): docgen
	if #fields == 0 then
		return
	end
	if not noTitle then
		self:pushTitle("Fields", titleIndent or 2)
	end
	self:pushProps(fields, titleIndent, true)
	return self
end

function docgen:pushFunctions(functions: { moonwave_high_function }, _titleIndent: number?, noTitle: boolean?): docgen
	if #functions == 0 then
		return
	end
	local titleIndent = _titleIndent or 2
	if not noTitle then
		self:pushTitle("Functions", titleIndent)
	end
	for index, item in functions do
		if item.ignore then
			continue
		end

		-- name
		self:pushTitle(docgen.strip(item.name), titleIndent + 1)

		-- attrs
		self:pushAttrs(item)

		-- comments
		if item.comments ~= "" then
			self:push(`{docgen.strip(item.comments)}\n\n`)
		end

		-- params
		if item.params then
			self:pushTitle("Parameters", titleIndent + 2)
			for _, param in item.params do
				if param.type then
					self:push(
						`- **{docgen.strip(param.name)}** {docgen.inline(docgen.strip(param.type))} {docgen.strip(
							param.description
						)}\n`
					)
				else
					self:push(`- {docgen.inline(docgen.strip(param.name))} {docgen.strip(param.description)}\n`)
				end
			end
			if item.returns then
				self:push("\n")
			end
		end

		-- returns
		if item.returns then
			self:pushTitle("Returns", titleIndent + 2)
			for _, return_ in item.returns do
				if return_.type then
					self:push(`- {docgen.inline(docgen.strip(return_.type))} {docgen.strip(return_.description)}\n`)
				else
					self:push(`- {docgen.strip(return_.description)}\n`)
				end
			end
		end

		-- errors
		if item.errors then
			self:pushTitle("Errors", titleIndent + 2)
			for _, error_ in item.errors do
				if error_.type then
					self:push(`- {docgen.inline(docgen.strip(error_.type))} {docgen.strip(error_.description)}\n`)
				else
					self:push(`- {docgen.strip(error_.description)}\n`)
				end
			end
		end

		-- hr
		if functions[index + 1] then
			self:pushHr()
		end
	end
	self:push("\n")
	return self
end

function docgen:pushMethods(methods: { moonwave_high_function }, titleIndent: number?, noTitle: boolean?): docgen
	if #methods == 0 then
		return
	end
	if not noTitle then
		self:pushTitle("Methods", titleIndent or 2)
	end
	self:pushFunctions(methods, titleIndent, true)
	return self
end

function docgen.filterConstructor(
	methods: { moonwave_high_function }
): ({ moonwave_high_function }, { moonwave_high_function }?)
	local filtered = {}
	local constructors = {}

	for _, method in methods do
		if (method.tags and table.find(method.tags, "Constructor")) or method.name == "new" then
			table.insert(constructors, method)
			continue
		end
		table.insert(filtered, method)
	end

	return filtered, if #constructors == 0 then nil else constructors
end

function docgen:pushClass(class: moonwave_high_class, _titleIndent: number?): docgen
	local titleIndent = _titleIndent or 1
	local childrenIndent = titleIndent + 1
	self:pushTitle(class.name, titleIndent)

	-- attrs
	self:pushAttrs(class)

	-- Filter constructors
	local functions: { moonwave_high_function }?
	local functionConstructors: { moonwave_high_function }?
	local methods: { moonwave_high_function }?
	local methodConstructors: { moonwave_high_function }?
	if class.functions then
		functions, functionConstructors = docgen.filterConstructor(class.functions)
	end
	if class.methods then
		methods, methodConstructors = docgen.filterConstructor(class.methods)
	end

	-- Push comments
	if class.comments ~= "" then
		self:pushComments(class.comments)
	end

	-- Push constructors
	if functionConstructors or methodConstructors then
		self:pushTitle("Constructors", childrenIndent)
		if functionConstructors then
			self:pushFunctions(functionConstructors, childrenIndent, false)
		end
		if methodConstructors then
			self:pushFunctions(methodConstructors, childrenIndent, false)
		end
	end

	-- Children
	if class.fields then
		self:pushFields(class.fields, childrenIndent)
	end
	if class.props then
		self:pushProps(class.props, childrenIndent)
	end
	if functions then
		self:pushFunctions(functions, childrenIndent)
	end
	if methods then
		self:pushMethods(methods, childrenIndent)
	end
	-- TODO: type

	return self
end

function docgen:pushComments(comments: string): docgen
	self:push(`{docgen.strip(comments)}\n\n`)
	return self
end

export type docgenSimpleFieldOptions = { withoutType: boolean?, withoutCommentLinebreak: boolean? }
function docgen:pushSimpleField(fields: { moonwave_high_field }, options: docgenSimpleFieldOptions?): docgen
	local withType = options and options.withType
	local withoutCommentLinebreak = options and options.withoutCommentLinebreak
	for _, field in fields do
		local comments = if field.comments == ""
			then ""
			else `{if withoutCommentLinebreak then " " else "\n\n"}{docgen.indent(
				docgen.strip(field.comments),
				"  "
			)}{if withoutCommentLinebreak then "" else "\n"}`
		if withType then
			self:push(`- **{docgen.strip(field.name)}** {docgen.inline(docgen.strip(field.type))}{comments}\n`)
		else
			self:push(`- {docgen.inline(docgen.strip(field.name))}{comments}\n`)
		end
	end
	return self
end

export type docgen = {
	new: () -> docgen,
	push: (self: docgen, str: string) -> docgen,
	finalize: (self: docgen) -> string,
	pushTitle: (self: docgen, str: string, level: number?) -> docgen,
	inline: (str: string) -> string,
	strip: (str: string) -> string,
	indent: (str: string, indent: string) -> string,
	pushHr: (self: docgen) -> docgen,
	pushSimpleField: (fields: { moonwave_high_field }, options: docgenSimpleFieldOptions?) -> docgen,
	pushProps: (
		self: docgen,
		props: { moonwave_high_field },
		titleIndent: number?,
		noTitle: boolean?
	) -> docgen,
	pushFields: (
		self: docgen,
		fields: { moonwave_high_field },
		titleIndent: number?,
		noTitle: boolean?
	) -> docgen,
	pushFunctions: (
		self: docgen,
		functions: { moonwave_high_function },
		titleIndent: number?,
		noTitle: boolean?
	) -> docgen,
	pushMethods: (
		self: docgen,
		methods: { moonwave_high_function },
		titleIndent: number?,
		noTitle: boolean?
	) -> docgen,
	pushAttrs: (self: docgen, item: moonwave_high_field | moonwave_high_function | moonwave_high_class) -> docgen,
	pushClass: (self: docgen, class: moonwave_high_class, titleIndent: number?) -> docgen,
	filterConstructor: (
		methods: { moonwave_high_function }
	) -> ({ moonwave_high_function }, { moonwave_high_function }?),
	pushComments: (self: docgen, comments: string) -> docgen,
}
--#endregion docgen, compat with lune docgen

local function parseString(content: string): moonwave_high
	local raw = moonwave_raw(content)
	local low = moonwave_low(raw)
	local middle = moonwave_middle(low)
	local high = moonwave_high(middle)
	return high
end

return {
	docgen = docgen,
	parseString = parseString,
	moonwave_high = moonwave_high,
	moonwave_middle = moonwave_middle,
	moonwave_low = moonwave_low,
	moonwave_raw = moonwave_raw :: any,
} :: {
	parseString: (content: string) -> moonwave_high,
	docgen: docgen,
	moonwave_raw: (content: string, startAt: number?) -> { [number]: { comments: string, linenums: { number } } },
	moonwave_low: (raw: moonwave_raw) -> moonwave_low,
	moonwave_middle: (low: moonwave_low) -> moonwave_middle,
	moonwave_high: (middle: moonwave_middle) -> moonwave_high,
}
