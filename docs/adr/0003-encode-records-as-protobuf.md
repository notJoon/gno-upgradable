# Encode Records as Protobuf

`Store` holds only plain values, so that a retired implementation keeps no
pointer into the proxy's state. State with several fields per key needs an
encoding, and that encoding must survive a rollback: an older implementation
runs again against records a newer one wrote, and the newer one may return.

A record is a protobuf message, stored as a `[]byte` row and read and
written with `gno.land/p/notjoon/encoding/protobuf/v0`. That package ports
Go's `protowire` and adds a message layer whose `Edit` keeps every field it
does not write. Protobuf parsers keep unknown fields by specification, which
is exactly what a rollback needs: v1 can rewrite a record without dropping
the fields v2 added.

Records follow the conventions in [record-format.md](../record-format.md):
field numbers are permanent, every write starts from the stored record,
field 1 holds the highest field number the last writer knew, signed integers
are `sint64`, and every field is written even when zero. A collection is a
table with one row per member, never a list inside a record.

`View` gets a typed getter for every type `Set` accepts, including
`GetBytes`, which returns a copy because stored bytes are readonly to the
caller. `p/upgrade` does not depend on the encoding package, so a record
format can change without a new proxy.

## Alternatives

- **A custom format.** A TLV prototype with type tags and a writer header
  worked and read for less gas, but no one else could read it or reuse it.
- **CBOR.** It distinguishes more types on the wire, but nothing in Gno or
  Cosmos uses it.
- **Struct values.** A struct type is frozen in its package, so adding a
  field means a type the older version cannot read.
- **One row per field.** Deleting an entity leaves the rows a newer version
  added, and every field costs a tree entry.

## Consequences

- Creating a record costs less than half the gas and a third of the storage
  of one row per field. Reading costs about 40% more. Updating costs more,
  because the whole record is decoded and re-encoded, so a value that changes
  on most calls belongs in its own row. See [protobuf.md](../protobuf.md#gas).
- The wire cannot tell `int64`, `uint64` and `bool` apart. The schema, written
  as a `.proto` comment in each implementation, is what keeps a field's type
  from drifting.
- Fields a newer version derived from older ones can go stale after a
  rollback. Field 1 lets the newer version detect that and repair on read.
