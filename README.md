
# moonwave-luau

Pure luau implementation for moonwave

# Uses

> **Note: You need to clone submodule too, try `git clone --recursive https://github.com/qwreey/moonwave-luau`**

This project has 4 stage. raw, low, middle, and high.

You can use

- moonwave_high
- moonwave_middle
- moonwave_low
- moonwave_raw

Function to perform each stage, or use parseString for get final result.

Please check type defines in init.luau for get result formats.

You can create document with `docgen`. See `example/init.luau`

# Example

To run example file, run `lune run example`.

# Limits

It does not always produce the same results as the official moonwave extractor.

# TODO

- interface tag
- source map (line info)
- external tag
- docgen types, static? etc (compat with lune-doc)
- type extract (!!)
