local fs = require("@lune/fs")
local moonwave = require("../")
local serde = require("@lune/serde")

local result_raw = moonwave.moonwave_raw(fs.readFile("./example/ffi.luau"))
fs.writeFile("./example/raw.json", serde.encode("json", result_raw, true))

local result_low = moonwave.moonwave_low(result_raw)
fs.writeFile("./example/low.json", serde.encode("json", result_low, true))

local result_middle = moonwave.moonwave_middle(result_low)
fs.writeFile("./example/middle.json", serde.encode("json", result_middle, true))

local result_high = moonwave.moonwave_high(result_middle)
fs.writeFile("./example/high.json", serde.encode("json", result_high, true))
