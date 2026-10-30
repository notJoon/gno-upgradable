package upgrade

import (
	"chain/runtime"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const owner address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

func TestApprove(cur realm, t *testing.T) {
	u := New(0, cur, owner, 0)
	for _, path := range []string{
		"gno.land/p/nt/avl/v0",
		"gno.land/p/x/r/y",
		"gno.land/e/g1user/run",
		"gno.land/r/x#sub",
		"gno.land/r/x`y",
		"gno.land/r/X",
		"gno.land/r/x y",
		"",
	} {
		uassert.PanicsWithMessage(t, cur, ErrInvalidPath, func() {
			u.approve(path)
		})
	}

	u.approve("gno.land/r/x/v1")
	u.approve("gno.land/r/x/v2")
	uassert.Equal(t, "gno.land/r/x/v2", u.Approved())
	uassert.Equal(t, "", u.PkgPath())
}

func TestDelay(cur realm, t *testing.T) {
	u := New(0, cur, owner, 10)
	h := runtime.ChainHeight()
	u.approve("gno.land/r/x/v1")
	uassert.Equal(t, h, u.ETA()) // nothing live yet, so no delay

	// With an implementation live, the delay waits for Prepare.
	u.pkgPath = "gno.land/r/x/v1"
	u.approve("gno.land/r/x/v2")
	uassert.Equal(t, int64(0), u.ETA())

	const maxInt64 = 1<<63 - 1
	uassert.Equal(t, int64(maxInt64), addDelay(maxInt64-10, 10))
	uassert.PanicsWithMessage(t, cur, ErrDelayOverflow, func() {
		addDelay(maxInt64, 1)
	})
}

func TestStore(cur realm, t *testing.T) {
	s := NewStore(0, cur)
	v := s.View()
	uassert.Equal(t, nil, v.Get("t", "k"))

	tx := s.Begin(0, cur)
	tx.Set("t", "b", int64(2))
	tx.Set("t", "a", int64(1))
	uassert.Equal(t, int64(1), v.Get("t", "a"))
	uassert.True(t, v.Has("t", "b"))

	tx.Set("t2", "c", int64(3)) // another table must not show up in t
	tx.Set("u", "d", int64(4))  // nor a table whose name sorts right after
	keys := ""
	v.Iterate("t", "", "", func(k string, _ any) bool {
		keys += k
		return false
	})
	uassert.Equal(t, "ab", keys)
	keys = ""
	v.Iterate("t", "b", "", func(k string, _ any) bool {
		keys += k
		return false
	})
	uassert.Equal(t, "b", keys)

	val, removed := tx.Remove("t", "a")
	uassert.True(t, removed)
	uassert.Equal(t, int64(1), val)
	uassert.False(t, v.Has("t", "a"))

	// Only plain values may be stored.
	uassert.PanicsWithMessage(t, cur, "upgrade: value must be string, bool, int64, uint64, address or []byte", func() {
		tx.Set("t", "p", &struct{ N int64 }{})
	})
	uassert.PanicsWithMessage(t, cur, "upgrade: value must be string, bool, int64, uint64, address or []byte", func() {
		tx.Set("t", "i", 1)
	})

	// A []byte is copied, so the writer keeps no handle on the stored one.
	b := []byte("x")
	tx.Set("t", "b", b)
	b[0] = 'y'
	uassert.Equal(t, "x", string(v.Get("t", "b").([]byte)))
}
