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
