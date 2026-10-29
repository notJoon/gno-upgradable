package upgrade

import (
	"chain/runtime"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestApprove(cur realm, t *testing.T) {
	u := New(0)
	for _, path := range []string{
		"gno.land/p/nt/avl/v0",
		"gno.land/p/x/r/y",
		"gno.land/e/g1user/run",
		"gno.land/r/x#sub",
		"",
	} {
		uassert.PanicsWithMessage(t, cur, ErrInvalidPath, func() {
			u.Approve(path)
		})
	}

	u.Approve("gno.land/r/x/v1")
	u.Approve("gno.land/r/x/v2")
	uassert.Equal(t, "gno.land/r/x/v2", u.Approved())
	uassert.Equal(t, "", u.PkgPath())

	u.Cancel()
	uassert.Equal(t, "", u.Approved())
	uassert.Equal(t, int64(0), u.ETA())
}

func TestDelay(cur realm, t *testing.T) {
	u := New(10)
	h := runtime.ChainHeight()
	u.Approve("gno.land/r/x/v1")
	uassert.Equal(t, h, u.ETA()) // nothing live yet, so no delay

	u.pkgPath = "gno.land/r/x/v1"
	u.Approve("gno.land/r/x/v2")
	uassert.Equal(t, h+10, u.ETA())
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
