# Records in proxy state

How an implementation stores a record, a value with several fields, in the
proxy's `Store` so that upgrades and rollbacks keep it intact. Decided in
[ADR 0003](adr/0003-encode-records-as-protobuf.md) for
[issue #5](https://github.com/notJoon/gno-upgradable/issues/5). The encoding
itself is described in [protobuf.md](protobuf.md), and
`src/r/upgrade/profile` is the worked example.

## Problem

`Tx.Set` stores six plain types. A contract whose state has records or
collections must pick a byte encoding, and the rollback rule makes the choice
harder than an ordinary schema change: a rolled back implementation runs
again against state that a newer version wrote, and the newer version may
later return.

Two naive approaches lose data across a rollback:

- **One blob, decoded and re-encoded by each version.** v2 adds a field, the
  proxy rolls back to v1, and v1 rewrites the record with only the fields it
  knows. Rolling forward, v2 reads its field as zero.
- **One row per field.** v1 deletes an entity by removing the rows it knows.
  The rows v2 added stay behind, and rolling forward finds half an entity.

## Prior art

| Format | Evolution model | Fit |
|---|---|---|
| Protocol Buffers | Numbered, tagged fields. Parsers keep unknown fields and write them back | Chosen. Unknown field preservation is exactly the rollback case |
| CBOR | Self describing items, maps with integer keys | Works too, but nothing in Gno or Cosmos uses it |
| Avro | Reader resolves the writer's schema | Needs the writer schema at read time, which means a schema registry on chain |
| Cap'n Proto, FlatBuffers | Fields at fixed offsets, read in place | Zero copy does not help in a VM that copies bytes anyway, and the layout code is large |
| Solidity proxies | Storage variables append only, with reserved gaps | Same append only rule, but slots are independent, so there is no record to rewrite |
| CosmWasm (serde JSON) | New fields get `#[serde(default)]`. Unknown fields are dropped on write | Shows the failure: an old binary silently drops new fields |

Also considered and dropped:

- **A custom format.** A positional TLV prototype with type tags and a
  writer header worked. It read for about 30% less gas and wrote for about
  the same, but nobody else could read it or reuse the package.
- **`gno.land/p/aib/encoding/proto/v0`.** It matches Cosmos SDK and IBC
  bytes, but has no decoder that skips unknown fields, and its repository
  has no license.
- **Struct values.** Their type is frozen in the package that declares it,
  so a new field means a new type that older versions cannot read.
- **JSON.** It costs more gas and cannot tell `int64` from `uint64`.

## Conventions

A record is a protobuf message stored as a `[]byte` row, read and written
with `gno.land/p/notjoon/encoding/protobuf/v0`.

1. **Field numbers are permanent.** A field number keeps its meaning and
   type forever. A new version adds fields with new numbers. A version keeps
   writing a field it no longer uses for as long as a rollback target reads
   it.
2. **Every write starts from the stored record.** Read the row, call
   `Edit` on it, set the fields this version knows, and store `Encode()`.
   Every field the version does not write, including fields a newer version
   added, is kept byte for byte.
3. **Field 1 names the last writer.** Every record has `uint64 writer = 1`,
   the highest field number the writing version knows. Each implementation
   sets it in the one helper all its writes go through. A newer version that
   finds a smaller number knows an older one rewrote the record since.
   Because `Edit` keeps unwritten fields, a version that forgot to set it
   would leave the newer number in place and hide the rewrite.
4. **Signed integers are `sint64`.** ZigZag keeps small negative values
   short. Records are not meant for off-chain parsers that expect Cosmos
   `int64` fields.
5. **Every field is written, even a zero.** `Has` then tells a zero from a
   missing field, so a field whose default is not zero can be filled lazily.
6. **Addresses are strings.** An `address` field is a protobuf `string`.

Write the schema next to the code as a `.proto` message in a comment, as
`src/r/upgrade/profile/v2/profile.gno` does. The proxy realm cannot change,
so each implementation documents the fields it knows.

```go
// edit starts every write, so that field 1 always names this version.
func edit(v upgrade.View, key string) *pb.Editor {
	e := pb.Read(v.GetBytes(Profiles, key)).Edit()
	e.Uint64(1, known)
	return e
}
```

### Fields derived from older fields

Keeping a field keeps its bytes, not its invariants. In the example, v2
records the height of the last name change. Rolled back, v1 changes the
name and keeps that height unchanged, so it is now stale. Back on v2, field
1 is 2, and v2 reports the height as a lower bound instead of the exact one.

A newer version must therefore either add only fields that stay valid however
older fields change, or check field 1 and repair or qualify records an older
version wrote. `Migrate` cannot repair them all when the table is larger than
one transaction's gas, so repair on read.

## Collections

A record holds a fixed set of fields, not a growing list. A collection is a
table with one row per member, keyed by the member's key, so that adding a
member writes one row instead of rewriting the collection. `Iterate` reads it
in key order. Keys that must sort numerically need fixed width, such as zero
padded decimals.

## Cost

See [protobuf.md](protobuf.md#gas) for measurements. In short, a record is
much cheaper than one row per field to create and store, about 40% dearer
to read, and dearer still to update, because an update decodes and re-encodes the whole
record. Keep a value that changes on most calls, such as a balance, in its
own row next to the record.

## Safety findings

- **View bytes cannot be modified.** An implementation that reads a `[]byte`
  through a `View` gets a readonly tainted slice. Writing to it fails with
  `cannot directly modify readonly tainted object`, and appending to it fails
  with `cannot append to readonly tainted slice`, even when the append would
  copy. A retained `View` therefore cannot alias stored records. `GetBytes`
  returns a copy so that callers can append to the result, and `Encode`
  builds a new slice.
- **Retired implementations keep no write access.** A record is a plain
  `[]byte` that `Set` copies into the proxy's tree. No pointer the
  implementation allocated is stored.
- **Rollback round trip.** The profile example's filetest installs v1, adds
  a field in v2, rolls back to v1, which rewrites the record, and rolls
  forward again:

  ```
  v1: alice
  v2: Alice, changed at block 17403 | bob
  v1: Alice Liddell
  v2: Alice Liddell, changed after block 17403
  v2: Alice, changed at block 51963
  ```

## Limits

- An update rewrites the whole record. Keep records small, and keep hot
  values in their own rows.
- A field cannot change type. The wire type check catches some mistakes,
  but `int64`, `uint64` and `bool` share one wire type.
- Unknown fields are kept byte for byte. Invariants between old and new
  fields are the newer version's job.
- Encoded bytes are not canonical. Compare decoded fields, not bytes.
