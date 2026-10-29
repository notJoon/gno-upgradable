package upgrade

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestApprove(cur realm, t *testing.T) {
	u := New()
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
}

func TestStore(cur realm, t *testing.T) {
	s := NewStore(0, cur)
	v := s.View()
	uassert.Equal(t, nil, v.Get("t", "k"))

	tx := s.Begin(0, cur)
	tx.Set("t", "b", 2)
	tx.Set("t", "a", 1)
	uassert.Equal(t, 1, v.Get("t", "a"))
	uassert.True(t, v.Has("t", "b"))

	tx.Set("t2", "c", 3) // another table must not show up in t
	tx.Set("u", "d", 4)  // nor a table whose name sorts right after
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
	uassert.Equal(t, 1, val)
	uassert.False(t, v.Has("t", "a"))
}
