<!-- markdownlint-disable -->

# FFI

> Note: **This library is technical preview**, not completed yet. Behaviors can be changed in future.

Built-in library for foreign function interface.

### Example usage
lib.c:
```c
int add(int a, int b) {
	return a + b;
}
```
init.luau:
```lua
local ffi = require("@lune/ffi")

-- Create function signature
local addSignature = ffi.c.fn({ ffi.c.int, ffi.c.int }, ffi.c.int)

-- Load library
local lib = ffi.open("./lib.so")

-- Get symbol from library
local addSymbol = lib:find("add")

-- Create CallableData
local add = addSignature:callable(addSymbol)

-- Create result box and arguments
local result = ffi.box(ffi.c.int.size)
local a = ffi.c.int:box(1)
local b = ffi.c.int:box(2)

-- Call external function
add(result, a:ref(), b:ref())

-- Get number from result
print(ffi.c.int:readData(result))
```

## Functions

### nullRef

**@must_use**

Create a `Ref` with address 0.

Can be used for receive a pointer from external function or pass it as an argument.

#### Returns

- A zero initialized Ref

---

### box

**@must_use**

Create a `Box` with specific size.
The created box is not filed with zero.

#### Parameters

- `size` The size of the new box

#### Returns

- A allocated box

---

### open

**@must_use**

Open a dynamic library.

#### Parameters

- `name` The name of the target library

#### Returns

- A dynamic library handle

---

### isInteger

**@must_use**

Return `true` if the second argument is an integer (i32).

#### Parameters

- `val` A lua value to check

#### Returns

- Whether val is an integer or not

---

### free

Free referenced memory.

#### Parameters

- `data` Target memory to free

## Properties

### C

`C`

Namespace for compile time sized c types.

## Types

Fixed size `CTypeInfo`s

- `u8`

  A 8-bit sized unsigned integer, Equivalent to `uint8_t` in `stdint`.

- `u16`

  A 16-bit sized unsigned integer, Equivalent to `uint16_t` in `stdint`.

- `u32`

  A 32-bit sized unsigned integer, Equivalent to `uint32_t` in `stdint`.

- `u64`

  A 64-bit sized unsigned integer, Equivalent to `uint64_t` in `stdint`.

- `u128`

  A 128-bit sized unsigned integer, Equivalent to `uint128_t` in `stdint`.

- `i8`

  A 8-bit sized signed integer, Equivalent to `int8_t` in `stdint`.

- `i16`

  A 16-bit sized signed integer, Equivalent to `int16_t` in `stdint`.

- `i32`

  A 32-bit sized signed integer, Equivalent to `int32_t` in `stdint`.

- `i64`

  A 64-bit sized signed integer, Equivalent to `int64_t` in `stdint`.

- `i128`

  A 128-bit sized signed integer, Equivalent to `int128_t` in `stdint`.

- `f32`

  A single-precision 32-bit sized floating-point, Almost always equivalent to `float` in C.

- `f64`

  A double-precision 64-bit sized floating-point, Almost always equivalent to `double` in C.

- `usize`

  A machine specific pointer sized unsigned integer.

- `isize`

  A machine specific pointer sized signed integer.

# C

Namespace for compile time sized c types.

## Functions

### fn

**@must_use**

Create a function signature type information.

#### Parameters

- `args` An array of CTypes represents the arguments of the function
- `ret` The return type of the function

#### Returns

- A function signature type information

---

### struct

**@must_use**

Create a struct type information.

#### Parameters

- `fields` An array of CTypes represents the fields of the struct

#### Returns

- A struct type information

## Types

Compile time size `CTypeInfo`s

- `char`

  Compiler defined C `char` type.
  
  The signedness may differ depending on the compiler and platform.
  
  You can get signedness by `signedness` field.

- `uchar`

  Compiler defined C `unsigned char` type.
  
  Mostly equivalent to `u8`.

- `schar`

  Compiler defined C `signed char` type.

- `short`

  Compiler defined C `short` type.

- `ushort`

  Compiler defined C `unsigned short` type.

- `int`

  Compiler defined C `int` type.
  
  The side may differ depending on the compiler and platform.

- `uint`

  Compiler defined C `unsigned int` type.
  
  The side may differ depending on the compiler and platform.

- `long`

  Compiler defined C `long` type.
  
  The side may differ depending on the compiler and platform.

- `ulong`

  Compiler defined C `unsigned long` type.
  
  The side may differ depending on the compiler and platform.

- `longlong`

  Compiler defined C `unsigned longlong` type.

- `longlong`

  Compiler defined C `unsigned longlong` type.

# Data

Classes for handling memory

## BoxData

A user manageable heap memory.

### Fields

#### size

**@readonly**

The size of the box.

### Methods

#### zero

Fill the box with zero.

##### Returns

- `BoxData` itself for convenience

---

#### leak

Create a reference of the box after leaking it.

GC doesn't manage destruction after this action. You must free it later.

##### Parameters

- `offset` Create a reference at the given offset

##### Returns

- A reference of the box

---

#### ref

**@must_use**

Create a reference of the box.

The created reference keeps the box from being garbage collected until the reference itself is collected.

##### Parameters

- `offset` Create a reference at the given offset

##### Returns

- A reference of the box

---

#### copyFrom

Copy content from another data with specific length.

##### Parameters

- `src` The source data
- `length` The amount of data to copy, in bytes
- `dstOffset` The offset in the destination where the content will be pasted
- `srcOffset` The offset in the source data from where the content will be copied

##### Returns

- `BoxData` itself for convenience

---

#### readString

**@must_use**

Read string from data with specific length without null termination.

##### Parameters

- `length` The amount of data to read, in bytes
- `offset` Offset to read string from

##### Returns

- A string

---

#### writeString

Write string into data without null termination.

##### Parameters

- `src` The source string
- `length` The amount of data to write, in bytes
- `dstOffset` The offset in the destination where the content will be pasted
- `srcOffset` The offset in the source string from where the content will be copied

##### Returns

- `BoxData` itself for convenience

## RefData

A user manageable memory reference.

It can be GCed, But it doesn't free the referenced memory.

### Methods

#### deref

**@must_use**

Create a RefData by dereference this reference.
The created reference has no boundaries and has no restrictions.

This method is unsafe.

##### Returns

- A dereferenced `RefData`

---

#### offset

**@must_use**

Create a reference with specific offset from this reference.

The created reference can be GCed and holds same data.

##### Parameters

- `offset` Create a reference at the given offset

##### Returns

- A offseted reference

---

#### ref

**@must_use**

Create a reference of this reference.

The created reference keeps the target reference from being garbage collected until created reference itself is collected.

##### Returns

- A reference of this reference

---

#### leak

Create a reference of this reference after leaking it.

GC doesn't manage destruction after this action. You must free it later.

##### Returns

- A reference of this reference

---

#### isNull

**@must_use**

Check reference is null or not.

##### Returns

- Whether reference is null or not

---

#### copyFrom

Copy content from another data with specific length.

##### Parameters

- `src` The source data
- `length` The amount of data to copy, in bytes
- `dstOffset` The offset in the destination where the content will be pasted
- `srcOffset` The offset in the source data from where the content will be copied

##### Returns

- `RefData` itself for convenience

---

#### readString

**@must_use**

Read string from data with specific length without null termination.

##### Parameters

- `length` The amount of data to read, in bytes
- `offset` Offset to read string from

##### Returns

- A string

---

#### writeString

Write string into data without null termination.

##### Parameters

- `src` The source string
- `length` The amount of data to write, in bytes
- `dstOffset` The offset in the destination where the content will be pasted
- `srcOffset` The offset in the source string from where the content will be copied

##### Returns

- `RefData` itself for convenience

## LibData

A dynamic opened library handle.

### Methods

#### find

**@must_use**

Find a symbol from the dynamic library.

##### Parameters

- `sym` The name of the symbol

##### Returns

- A `Ref` of the found symbol

## CallableData

A callable external function.

To call external function, provide memory for save the return value and references for the arguments.

If return type is `void`, pass `nil`.

## ClosureData

A reference that holds lua function.

### Methods

#### ref

**@must_use**

Create a reference of the closure. usually can be used for passing function pointer as argument.

The created reference keeps the closure from being garbage collected until the reference itself is collected.

##### Returns

- A reference of the closure

# Info

Type informations, which provide type conversion, casting, stringify, etc...

## CTypeInfo

A c numbric type information.

### Fields

#### size

**@readonly**

The size of the type in bytes.

---

#### signedness

**@readonly**

The signedness of the type.

### Methods

#### ptr

**@must_use**

Create a pointer subtype.

##### Returns

- A pointer subtype

---

#### arr

**@must_use**

Create an array subtype with specific length.

##### Parameters

- `length` The length of the array

##### Returns

- An array subtype

---

#### box

**@must_use**

Create a box with initial values.

##### Parameters

- `table` The array of element values

##### Returns

- A box

---

#### readData

**@must_use**

Read a lua value from reference or box.

##### Parameters

- `target` Target to read data from
- `offset` Offset to read data from

##### Returns

- A lua value

---

#### writeData

Write a lua value into reference or box.

##### Parameters

- `target` Target to write data into
- `value` Lua data to write
- `offset` Offset to write data into

---

#### copyData

Copy values from the source and paste them into the target.

##### Parameters

- `dst` Where the content will be pasted
- `src` The source data
- `dstOffset` The offset in the destination where the content will be pasted
- `srcOffset` The offset in the source data from where the content will be copied

---

#### stringifyData

**@must_use**

Stringify data. Useful when output numbers, which Luau can't handle.

##### Parameters

- `target` The target data
- `offset` Offset to stringify data from

##### Returns

- A stringified data

---

#### cast

Casting data to different type.

May result in loss of precision.

##### Parameters

- `intoType` The target type to convert to
- `fromData` Source data to be converted
- `intoData` Target to write converted data into
- `fromOffset` The offset in the source data
- `intoOffset` The offset in the destination

## CPtrInfo

A c pointer type information.

### Fields

#### size

**@readonly**

The size of a pointer. should be the same for all pointers.

Equivalent to `ffi.c.usize.size`.

---

#### inner

**@readonly**

The inner type of the pointer.

### Methods

#### arr

**@must_use**

Create an array subtype with specific length.

##### Parameters

- `length` The length of the array

##### Returns

- An array subtype

---

#### ptr

**@must_use**

Create a pointer subtype.

##### Returns

- A pointer subtype

---

#### readRef

**@must_use**

Read address from data, then return RefData.

Useful when reading pointer fields of structures.

If the `ref` argument is given, rather than create new RefData, update it.

##### Parameters

- `target` Target data to read address from
- `offset` Offset to read address from
- `ref` RefData to update

##### Returns

- A lua value

---

#### writeRef

**@must_use**

Write address to data.
	
Useful when writing pointer fields of structures.

##### Parameters

- `target` Target data to write address into
- `ref` Memory address to write
- `offset` Offset to write address into

## CArrInfo

A c sized array type information. It can be used for sturct field.

For function arguments, use CPtr instead.

### Fields

#### size

**@readonly**

The total size of the array in bytes.

---

#### length

**@readonly**

The length of the array.

---

#### inner

**@readonly**

The inner element type of the array.

### Methods

#### ptr

**@must_use**

Create a pointer subtype.

##### Returns

- A pointer subtype

---

#### box

**@must_use**

Create a box with initial values.

##### Parameters

- `table` The array of field values

##### Returns

- A box

---

#### readData

**@must_use**

Read a lua table from reference or box.

##### Parameters

- `target` Target to read data from
- `offset` Offset to read data from

##### Returns

- A table

---

#### writeData

**@must_use**

Write a lua table into reference or box.

##### Parameters

- `target` Target to write data into
- `table` Lua data to write
- `offset` Offset to write data into

---

#### copyData

Copy values from the source and paste them into the target.

##### Parameters

- `dst` Where the content will be pasted
- `src` The source data
- `dstOffset` The offset in the dst where the content will be pasted
- `srcOffset` The offset in the source data from where the content will be copied

---

#### offset

**@must_use**

Get the byte offset of the field.

##### Parameters

- `index` The element index

##### Returns

- The byte offset

## CFnInfo

A C function pointer type information, with function signature.

For struct field, array element, or function arguments, use `void:ptr()` instead.

### Fields

#### size

**@readonly**

The size of a function pointer.

Equivalent to `ffi.c.usize.size`.

### Methods

#### callable

**@must_use**

Create a callable from reference.

##### Returns

- A callable

---

#### closure

**@must_use**

Create a closure from lua function.

To return some data, lua function should write value into ret reference.

##### Returns

- A closure

## CStructInfo

A c struct type information.

### Fields

#### size

**@readonly**

The size of a struct, including padding.

## CVoidInfo

A type that represents c void. can only be used for the function return type.

### Fields

#### size

**@readonly**

The size of the void type. It is always 0.

### Methods

#### ptr

**@must_use**

Create a generic pointer type.

##### Returns

- Generic pointer type, equivalent to `*void` in C.
