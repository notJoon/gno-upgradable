package upgrade

import (
	"chain"
	"strings"

	"gno.land/p/nt/bptree/v0"
)

const ErrNotOwner = "upgrade: rlm is not the store owner's live cur"

// Store is a proxy's state: a set of named tables, each an ordered map from
// string keys to values. NewProxy creates one and the Proxy keeps it.
//
// Implementations never see the tables themselves. They read through a View
// and write through a Tx, which only the proxy can open and which cannot be
// stored, so an implementation keeps no access to the state once the proxy
// stops calling it.
//
// All tables share one ordered tree, keyed by table name and row key, so a
// table costs nothing until it has rows. The tree and every node it grows
// are allocated by the Store's own methods and belong to the proxy, even
// when an implementation's write adds a table, so later versions can add
// tables without changing the proxy.
//
// Values are limited to plain types (see Tx.Set). Anything holding a pointer
// allocated by an implementation would stay writable by that implementation
// after it has been replaced, through any View it kept.
type Store struct {
	owner string
	rows  *bptree.BPTree // table + sep + key -> value
}

// sep ends a table name inside a row key. Table names must not contain it.
const sep = "\x00"

// NewStore returns an empty store owned by the realm whose live cur is rlm.
func NewStore(_ int, rlm realm) *Store {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}
	return &Store{owner: rlm.PkgPath(), rows: bptree.NewBPTree32()}
}

// Begin opens a write transaction. rlm must be the owner's live cur. The Tx
// holds rlm, so it is valid only while that crossing frame is live, and
// storing it anywhere aborts the transaction.
func (s *Store) Begin(_ int, rlm realm) *Tx {
	if !rlm.IsCurrent() || rlm.PkgPath() != s.owner {
		panic(ErrNotOwner)
	}
	return &Tx{s: s, rlm: rlm}
}

// View returns a read-only handle on the store. Holding one grants no write
// access, so it may be given to anyone and retained across calls.
func (s *Store) View() View {
	return View{s: s}
}

func rowKey(table, key string) string {
	if strings.Contains(table, sep) {
		panic("upgrade: invalid table name")
	}
	return table + sep + key
}

// ---------------------------------------------------

// Tx writes to a store on behalf of its owner during one crossing call.
type Tx struct {
	s         *Store
	rlm       realm
	sentTaken bool
}

// Sent returns the coins sent with this call, and tells the proxy the
// implementation has taken them.
func (tx *Tx) Sent() chain.Coins {
	tx.assertLive()
	tx.sentTaken = true
	return tx.sent()
}

// Caller returns the address of the account or realm that called the
// owner.
func (tx *Tx) Caller() address {
	tx.assertLive()
	return tx.rlm.Previous().Address()
}

// Emit emits an event with a "realm" attribute naming the store's owner.
// An implementation should emit through it rather than chain.Emit, whose
// pkg_path would name the implementation and change with every upgrade.
func (tx *Tx) Emit(typ string, attrs ...string) {
	tx.assertLive()
	chain.Emit(typ, append([]string{"realm", tx.s.owner}, attrs...)...)
}

// View returns a read-only handle on the same store.
func (tx *Tx) View() View {
	return tx.s.View()
}

// Set stores value, which must be a string, bool, int64, uint64, address or
// []byte. A []byte is copied. Any other type panics, including int, so that
// versions cannot drift between int and int64 for the same row.
func (tx *Tx) Set(table, key string, value any) {
	tx.assertLive()
	switch v := value.(type) {
	case string, bool, int64, uint64, address:
	case []byte:
		value = append([]byte(nil), v...)
	default:
		panic("upgrade: value must be string, bool, int64, uint64, address or []byte")
	}
	tx.s.rows.Set(rowKey(table, key), value)
}

func (tx *Tx) Remove(table, key string) (value any, removed bool) {
	tx.assertLive()
	return tx.s.rows.Remove(rowKey(table, key))
}

// assertLive panics unless the owner's frame is live, so a Tx handed to code
// the owner cross-called cannot write.
func (tx *Tx) assertLive() {
	if !tx.rlm.IsCurrent() {
		panic(ErrNotOwner)
	}
}

// ---------------------------------------------------

// View reads a store. A table with no rows reads as empty.
type View struct {
	s *Store
}

func (v View) Get(table, key string) any {
	return v.s.rows.Get(rowKey(table, key))
}

// There is a typed getter for each type Set accepts. Each returns the zero
// value if there is no row, and panics if the row holds another type.

func (v View) GetString(table, key string) string {
	x := v.Get(table, key)
	s, ok := x.(string)
	assertType(x, ok, table, key, "string")
	return s
}

func (v View) GetBool(table, key string) bool {
	x := v.Get(table, key)
	b, ok := x.(bool)
	assertType(x, ok, table, key, "bool")
	return b
}

func (v View) GetInt64(table, key string) int64 {
	x := v.Get(table, key)
	n, ok := x.(int64)
	assertType(x, ok, table, key, "int64")
	return n
}

func (v View) GetUint64(table, key string) uint64 {
	x := v.Get(table, key)
	n, ok := x.(uint64)
	assertType(x, ok, table, key, "uint64")
	return n
}

func (v View) GetAddress(table, key string) address {
	x := v.Get(table, key)
	a, ok := x.(address)
	assertType(x, ok, table, key, "address")
	return a
}

// GetBytes returns a copy, because the stored bytes are readonly to the
// caller and appending to them would panic.
func (v View) GetBytes(table, key string) []byte {
	x := v.Get(table, key)
	b, ok := x.([]byte)
	assertType(x, ok, table, key, "[]byte")
	return append([]byte(nil), b...)
}

func assertType(x any, ok bool, table, key, typ string) {
	if !ok && x != nil {
		panic("upgrade: row " + table + "/" + key + " is not " + typ)
	}
}

func (v View) Has(table, key string) bool {
	return v.s.rows.Has(rowKey(table, key))
}

// Iterate visits the keys of a table in [start, end) in ascending order
// until cb returns true. An empty start or end leaves that side unbounded.
// cb must not write to the store.
func (v View) Iterate(table, start, end string, cb func(key string, value any) bool) bool {
	prefix := rowKey(table, "")
	hi := prefix + end
	if end == "" {
		hi = table + "\x01" // the first key after every row of table
	}
	return v.s.rows.Iterate(prefix+start, hi, func(k string, value any) bool {
		return cb(k[len(prefix):], value)
	})
}
