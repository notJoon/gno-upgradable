package upgrade

import (
	"chain/runtime"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const owner address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

func TestApprove(cur realm, t *testing.T) {
	p := NewProxy(0, cur, owner, 0, 1)
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
			p.approve(path)
		})
	}

	p.approve("gno.land/r/x/v1")
	p.approve("gno.land/r/x/v2")
	uassert.Equal(t, "gno.land/r/x/v2", p.Approved())
	uassert.Equal(t, "", p.ImplPath())
}

func TestDelay(cur realm, t *testing.T) {
	p := NewProxy(0, cur, owner, 10, 5)
	h := runtime.ChainHeight()
	p.approve("gno.land/r/x/v1")
	uassert.Equal(t, h, p.ETA()) // nothing live yet, so no delay

	// With an implementation live, the delay waits for the first Upgrade call.
	p.implPath, p.impl = "gno.land/r/x/v1", lifecycleOnly{}
	p.approve("gno.land/r/x/v2")
	uassert.Equal(t, int64(0), p.ETA())

	// A saved value installs from the ETA until the window closes.
	p.pending, p.eta = lifecycleOnly{}, h+1
	uassert.PanicsWithMessage(t, cur, ErrTooEarly, func() { p.assertInstallable() })
	p.eta = h
	p.assertInstallable()
	p.eta = h - 4
	p.assertInstallable()
	p.eta = h - 5
	p.assertInstallable()
	p.eta = h - 6
	uassert.PanicsWithMessage(t, cur, ErrExpired, func() { p.assertInstallable() })

	// Approving again drops the saved value and its ETA.
	p.approve("gno.land/r/x/v2")
	uassert.True(t, p.pending == nil)
	uassert.Equal(t, int64(0), p.ETA())

	const maxInt64 = 1<<63 - 1
	uassert.Equal(t, int64(maxInt64), addDelay(maxInt64-10, 10))
	uassert.PanicsWithMessage(t, cur, ErrDelayOverflow, func() {
		addDelay(maxInt64, 1)
	})
	uassert.PanicsWithMessage(t, cur, ErrDelayOverflow, func() {
		NewProxy(0, cur, owner, 1, maxInt64)
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

type dupMethods struct{}

func (dupMethods) Migrate(tx *Tx, c *Custody, from ImplRef) {}
func (dupMethods) Methods() (calls, queries []Method) {
	return []Method{{Name: "Call", Schema: "v1"}, {Name: "Call", Schema: "v2"}}, nil
}
func (dupMethods) Call(tx *Tx, c *Custody, method, args string) string { return "" }
func (dupMethods) Query(v View, method, args string) string            { return "" }

type uncomparable struct{ xs []int }

func (uncomparable) Migrate(tx *Tx, c *Custody, from ImplRef) {}

type oneMethod struct{ dupMethods }

func (oneMethod) Methods() (calls, queries []Method) {
	return []Method{{Name: "Call", Schema: "v1"}}, nil
}

func TestInspectImpl(cur realm, t *testing.T) {
	p := NewProxy(0, cur, owner, 0, 1)
	uassert.PanicsWithMessage(t, cur, "upgrade: duplicate Call method Call", func() {
		p.InspectImpl(dupMethods{})
	})
	uassert.PanicsWithMessage(t, cur, "upgrade: implementation must be comparable", func() {
		p.InspectImpl(uncomparable{})
	})
	candidate := p.InspectImpl(lifecycleOnly{})
	uassert.Equal(t, 0, len(candidate.Calls)+len(candidate.Queries))
	uassert.Equal(t, 0, len(candidate.MissingCalls)+len(candidate.MissingQueries))
	candidate = p.InspectImpl(oneMethod{})
	uassert.Equal(t, 1, len(candidate.Calls))
	uassert.True(t, candidate.Calls[0] == (Method{Name: "Call", Schema: "v1"}))
	uassert.Equal(t, 0, len(candidate.Queries)+len(candidate.MissingCalls)+len(candidate.MissingQueries))
}

type lifecycleOnly struct{}

func (lifecycleOnly) Migrate(tx *Tx, c *Custody, from ImplRef) {}

func TestLifecycleOnlyImplementation(cur realm, t *testing.T) {
	p := NewProxy(0, cur, owner, 0, 1)
	p.impl = lifecycleOnly{}
	p.Invoke(0, cur, func(impl Impl, tx *Tx, _ *Custody) {
		uassert.True(t, impl == Impl(lifecycleOnly{}))
		tx.sentTaken = true
		tx.Set("typed", "value", "ok")
	})
	p.Inspect(func(_ Impl, v View) {
		uassert.Equal(t, "ok", v.Get("typed", "value"))
	})
	calls, queries := p.Methods()
	uassert.Equal(t, 0, len(calls)+len(queries))
}

func TestLifecycleOnlyQueryReportsUnknownMethod(cur realm, t *testing.T) {
	p := NewProxy(0, cur, owner, 0, 1)
	p.impl = lifecycleOnly{}
	uassert.PanicsWithMessage(t, cur, "upgrade: unknown method Nope", func() {
		p.Query("Nope", "")
	})
}
