# piece-table

A [piece table](https://en.wikipedia.org/wiki/Piece_table) implementation.

## Features

- **Append**: Append a buffer to the end.
- **Insert**: Insert a buffer at a given position.
- **Delete**: Delete a character at a given position.
- **Render**: Render the piece table into a writer or buffer.
- **Length**: Retrieve the accumulated length of each element in the table.

## Overview

A piece table is a simple data structure that efficiently tracks edits to a
buffer. The piece table, as the name suggests, contains rows of buffer locations
and positions within the buffers. The piece table is initialized with a read-ony
buffer. The implementation also maintains an append-only data buffer that holds
the insertion data.

Insertions are implemented by first appending the insertion data to the
read-write vector, then inserting a record into the table referring to the
positions of this newly-inserted data.

Deletions are currently implemented by shrinking the buffer length by one byte.

Rendering the table is as simple as iterating the rows of the table and writing
the referenced to the destination buffer.

## C library

A C library is exported by the `ffi` target. To build the C library, run:
```shell
zig build ffi
```
