package upgrade

import (
	"strings"

	"gno.land/p/nt/bptree/v0"
)

const ErrNotOwner = "upgrade: rlm is not the store owner's live cur"

// Store is a proxy's state: a set of named tables, each an ordered map from
// string keys to values. The proxy creates it from init and keeps it in an
// unexported variable.
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
// Store values, not pointers. A pointer value that an implementation
// allocated belongs to that implementation, which can keep writing through
// it after it has been replaced.
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
// access, so it may be given to anyone.
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
	s   *Store
	rlm realm
}

// Caller returns the address of the account or realm that called the
// owner.
func (tx *Tx) Caller() address {
	return tx.rlm.Previous().Address()
}

// View returns a read-only handle on the same store.
func (tx *Tx) View() View {
	return tx.s.View()
}

func (tx *Tx) Set(table, key string, value any) {
	tx.assertLive()
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

func (v View) Has(table, key string) bool {
	return v.s.rows.Has(rowKey(table, key))
}

// Iterate visits the keys of a table in [start, end) in ascending order
// until cb returns true. An empty start or end leaves that side unbounded.
func (v View) Iterate(table, start, end string, cb bptree.IterCbFn) bool {
	prefix := rowKey(table, "")
	hi := prefix + end
	if end == "" {
		hi = table + "\x01" // the first key after every row of table
	}
	return v.s.rows.Iterate(prefix+start, hi, func(k string, value any) bool {
		return cb(k[len(prefix):], value)
	})
}
