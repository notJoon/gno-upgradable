# Protobuf wire format

A summary of the official Protocol Buffers specification, kept as the
reference for a Gno encoding package and for the record format of
[issue #5](https://github.com/notJoon/gno-upgradable/issues/5). Section links
point to the copies in `docs/spec/protobuf/`.

## Sources

Copied from
[protocolbuffers/protocolbuffers.github.io](https://github.com/protocolbuffers/protocolbuffers.github.io)
at commit `c4bd0dfa0cd755aedccdf001814a99017003c32a`, under the BSD 3-Clause
license in [`spec/protobuf/LICENSE`](spec/protobuf/LICENSE).

| File | Upstream path | Covers |
|---|---|---|
| [encoding.md](spec/protobuf/encoding.md) | `content/programming-guides/encoding.md` | The wire format |
| [proto3.md](spec/protobuf/proto3.md) | `content/programming-guides/proto3.md` | Field numbers, defaults, updating messages, unknown fields |
| [proto3-spec.md](spec/protobuf/proto3-spec.md) | `content/reference/protobuf/proto3-spec.md` | `.proto` grammar |
| [field_presence.md](spec/protobuf/field_presence.md) | `content/programming-guides/field_presence.md` | Implicit and explicit presence |
| [serialization-not-canonical.md](spec/protobuf/serialization-not-canonical.md) | `content/programming-guides/serialization-not-canonical.md` | Why encoded bytes are not canonical |
| [proto-limits.md](spec/protobuf/proto-limits.md) | `content/programming-guides/proto-limits.md` | Field number and size limits |

## Wire format

A message is a sequence of records, each a tag followed by a value. Fields
may appear in any order.

```none
message    := (tag value)*
tag        := (field << 3) | wire_type, encoded as a uint32 varint
value      := varint      for VARINT
              4 bytes     for I32, little endian
              8 bytes     for I64, little endian
              len payload for LEN, len is a varint
```

| ID | Wire type | Proto types |
|---|---|---|
| 0 | VARINT | int32, int64, uint32, uint64, sint32, sint64, bool, enum |
| 1 | I64 | fixed64, sfixed64, double |
| 2 | LEN | string, bytes, embedded messages, packed repeated fields |
| 3 | SGROUP | group start, deprecated |
| 4 | EGROUP | group end, deprecated |
| 5 | I32 | fixed32, sfixed32, float |

### Varints

Base 128, little endian groups of 7 bits, with the high bit of each byte set
when more bytes follow. A varint takes 1 to 10 bytes. `encoding/binary`'s
`AppendUvarint` and `Uvarint` produce and read exactly this.
([encoding.md#varints](spec/protobuf/encoding.md))

### Integers

- `int32` and `int64` store negative numbers in two's complement, so every
  negative value takes all 10 bytes.
- `sint32` and `sint64` use ZigZag first: `(n << 1) ^ (n >> 63)`, so small
  negative numbers stay small. This is `binary.AppendVarint` in Go and Gno.
- `bool` is a varint, always `00` or `01`.
- `fixed64`, `sfixed64` and `double` take 8 bytes. `fixed32`, `sfixed32`
  and `float` take 4.

### Length delimited values

`string` (valid UTF-8), `bytes`, embedded messages and packed repeated
fields are a varint length and then the payload. An embedded message is
encoded exactly like a top level one. A string or bytes field holds at most
2 GB.

### Missing fields

A field that is not present has no record at all.

### Repeated fields and maps

- A repeated scalar field is packed by default: one LEN record holding the
  values back to back. Parsers must accept both packed and unpacked records
  for any repeated scalar field, and must concatenate several packed
  records for the same field.
- Records of a repeated field may interleave with other fields. Only their
  order relative to each other is kept.
- `map<K, V>` is a repeated message with `key = 1` and `value = 2`. Entry
  order is not preserved.

### Last one wins

When a non-repeated field appears more than once, a parser keeps the last
scalar or string value, and merges embedded messages. Parsing the
concatenation of two messages therefore equals parsing both and merging.
([encoding.md#last-one-wins](spec/protobuf/encoding.md))

### Groups

SGROUP and EGROUP are deprecated delimiters that remain in the wire format.
proto3 does not define groups.

## Field numbers

- A field number is between 1 and 2^29 - 1. Numbers 19,000 to 19,999 are
  reserved for the implementation.
- Numbers 1 to 15 take one tag byte. Numbers 16 to 2047 take two.
- A number identifies the field on the wire and must never change or be
  reused. Delete a field by listing its number, and its name, under
  `reserved`.
  ([proto3.md#assigning](spec/protobuf/proto3.md),
  [proto3.md#deleting](spec/protobuf/proto3.md))

## Changing a schema

([proto3.md#updating](spec/protobuf/proto3.md))

| Kind | Changes |
|---|---|
| Wire safe | Add a field. Remove a field and reserve its number. Add an enum value |
| Wire compatible, possibly lossy | `int32`, `uint32`, `int64`, `uint64` and `bool` among themselves. `sint32` with `sint64`. `string` with `bytes` when valid UTF-8. An embedded message with `bytes`. `fixed32` with `sfixed32`, `fixed64` with `sfixed64` |
| Wire unsafe | Change a field number. Move a field into an existing `oneof` |

The compatible group is where type mistakes hide: the wire cannot tell
`int64`, `uint64` and `bool` apart, and the spec calls reading a field
under a different definition data corruption in the best case.
`sint64` is not compatible with the other integer types.

## Unknown fields

A field the parser does not recognize is an unknown field. proto3 parsers
keep unknown fields and write them back when they serialize the message.
Copying a message field by field, or through JSON, loses them.
([proto3.md#unknowns](spec/protobuf/proto3.md))

This is the property a rollback needs: an older implementation that
rewrites a record keeps the fields a newer one added.

## Presence and defaults

- The wire format only ever holds present fields.
  ([field_presence.md](spec/protobuf/field_presence.md))
- Under *implicit presence*, the proto3 default for plain fields, a field
  holding its default value (0, false, empty) is not written, and a reader
  cannot tell it from a missing one.
- Under *explicit presence*, `optional` in proto3, a set field is written
  even when it holds the default, and the reader can ask whether it is set.
  The spec recommends `optional` for proto3 scalar fields by default.
- A missing field reads as the type's default: empty string or bytes,
  false, or 0. ([proto3.md#default](spec/protobuf/proto3.md))

## Not canonical

Serialization is not canonical, and not even deterministic across
implementations. Field order is unspecified, and unknown fields are
usually written after known ones. Do not hash or compare encoded bytes to
test equality. ([serialization-not-canonical.md](spec/protobuf/serialization-not-canonical.md))

## Limits

([proto-limits.md](spec/protobuf/proto-limits.md))

- A serialized message must be under 2 GiB.
- A message has at most 65,535 fields.
- Parsers limit nesting depth: 100 in C++ and Java.

## The Gno package

`gno.land/p/notjoon/encoding/protobuf/v0` has two layers.

### Wire layer: `wire.gno`

A port of Go's `google.golang.org/protobuf/encoding/protowire` v1.36.12,
with the same API: `AppendTag`, `AppendVarint`, `ConsumeTag`,
`ConsumeField`, `ConsumeFieldValue`, `EncodeZigZag` and the rest. Functions
report errors as a negative length, which `ParseError` turns into an error,
so code that handles untrusted bytes can refuse them without panicking.

The port changes only what Gno requires: the package name, the stdlib
`errors` package instead of protobuf's internal one, and a plain
`SizeVarint`. Upstream's `wire_test.go` runs unchanged apart from a
benchmark that needs `slices`. The BSD 3-Clause license ships with the
package.

### Message layer: `message.gno`

Code with no generated types reads and edits one message by field number.

```go
m := protobuf.Read(b) // parses b once, panics if malformed
balance := m.Sint64(2) // default value if missing, panics on another wire type

e := m.Edit()
e.Sint64(2, balance+1)
b = e.Encode() // written fields, then every other field of m unchanged
```

- `Read` checks every record and indexes them, so each getter is a lookup.
  When a field appears more than once, the last one wins.
- Getters exist for `int64`, `sint64`, `uint64`, `bool`, `string`, `bytes`
  and embedded messages. `Has` reports presence.
- Setters always write the field, even a zero value, so `Has` tells a zero
  from a missing field. This is explicit presence, and still valid proto3.
- `Encode` drops every old occurrence of a written field and keeps all other
  fields byte for byte. Unknown fields survive an edit, as the spec requires,
  which is what a rollback needs.
- The message layer panics on bad input, so a realm aborts rather than act
  on it. Use the wire layer to handle errors instead.

### Gas

Measured on gno v1.7.0 with throwaway realms and the filetest `Gas`
directive: a four field entity read and written through a proxy, with the
call overhead subtracted. The TLV column is a custom format tried first and
dropped for this one.

| Operation | Four rows | TLV prototype | protobuf |
|---|---|---|---|
| Insert, average of 20 | 668k gas, 3,073 bytes | 283k gas, 998 bytes | 311k gas, 992 bytes |
| Read all fields | 208k | 211k | 298k |
| Update one field | 144k | 550k | 370k |
| Update all fields | 412k | 550k | 564k |

The first version rescanned the message in every getter and cost 856k to
read. Indexing once in `Read` brought it to 362k, and parsing one byte tags
and lengths inline, which most records use, to 298k. Of that, parsing takes
about 114k, the getters about 120k, and the store read 48k.

### Mapping Gno values

| Gno type | Proto type | Wire type |
|---|---|---|
| `string` | `string` | LEN |
| `bool` | `bool` | VARINT |
| `int64` | `sint64` or `int64` | VARINT |
| `uint64` | `uint64` | VARINT |
| `address` | `string` (bech32) | LEN |
| `[]byte` | `bytes` | LEN |
| nested record | message | LEN |

### Decisions left for the record format

- `int64` as `sint64`, which keeps negative values short, or as `int64`,
  which matches Cosmos messages. They are not wire compatible, so the choice
  is per field and permanent.
- How a newer version learns that an older one rewrote a record, which the
  TLV prototype's `writer` header did. In protobuf this would be an ordinary
  field that every writer sets, such as the highest field number it knows.
- Publishing a `.proto` file per table, so that off-chain tools decode the
  records with generated code.
