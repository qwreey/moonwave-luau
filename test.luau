local fs = require("@lune/fs")
local moonwave = require("./")

local result = moonwave.parseString(fs.readFile("../lune/types/ffi.luau"))
print(result)
