package upgrade

import (
	"chain"
	"chain/runtime/unsafe"
	"strings"
)

const ErrUnexpectedCoins = "upgrade: method did not take the coins sent with it"

// Impl is what an implementation realm provides. Its API is the proxy's
// API: the proxy forwards every call by method name, so a later version can
// add methods without changing the proxy.
//
// # The API only grows
//
// The proxy's API is every method any implementation has served. A new
// implementation must answer all of them: it may add methods but not drop
// any, because callers of a permanent address cannot be told to change.
// There is no option to allow a drop. To retire a method, keep it listed
// and make it panic with a reason, such as "Withdraw was retired, use
// WithdrawTo".
//
// A rollback is the one exception. A path that served before cannot know
// the methods added after it, so returning to one may leave some of the
// API unavailable until a version that has them comes back. Those methods
// stay in the API, so a version after the rollback must answer them again.
// Comparing against the current implementation instead would let an owner
// drop a method by rolling back and then upgrading.
//
// args is passed through as is. Each implementation chooses its encoding.
type Impl interface {
	// Methods lists the method names Call and Query answer. The proxy
	// refuses any other name before the implementation runs, and checks
	// the lists against the API when the implementation registers. Keep
	// them in step with Call and Query: nothing checks they agree, and a
	// listed name Call does not handle reaches its default case.
	//
	// The two lists are separate because moving a method from Query to
	// Call also breaks its callers. Only names are compared, so a method
	// whose args change meaning is not caught.
	Methods() (calls, queries []string)

	// Migrate runs once when the implementation registers. from is the
	// implementation it replaces, or empty for the first one. tx.Caller()
	// is the registering realm.
	Migrate(tx *Tx, c *Custody, from string)
	Call(tx *Tx, c *Custody, method, args string) string
	Query(v View, method, args string) string
	Render(v View, path string) string
}

// Proxy is the state of an upgradable realm: who may become its
// implementation, its Store, and the live implementation. The realm creates
// it from init, keeps it in an unexported variable, and forwards its
// crossing functions to it.
//
// # Rolling back
//
// There is no Rollback. Going back to an older implementation is an
// ordinary upgrade to it: the owner approves the old realm's path, the
// delay runs, and the old realm registers again. So every implementation
// should export a crossing function that calls Register, such as Activate,
// rather than registering only from init, which never runs twice.
//
// The delay applies to rollbacks on purpose. Users accepted the old code
// against older state, and some may have left because of it. An instant
// rollback would let the owner put that code back before they can react.
//
// The old implementation usually lacks methods the newer one added. They
// report as unavailable until a version that has them is back. See Impl.
//
// Rolling back changes code, not state:
//   - The old implementation's Migrate runs with from set to the newer
//     path, and must accept it. A Migrate that allows only specific
//     predecessors blocks the rollback.
//   - Tables the newer version added stay in the Store. The old version
//     ignores them, and rolling forward again finds them intact.
//   - Rows the newer version rewrote must still be readable by the old one.
//     A version that changes a row's format in place makes rolling back
//     unsafe, so prefer adding a new table.
//   - Coins stay at the proxy's address throughout.
type Proxy struct {
	u     *Upgrader
	store *Store
	impl  Impl

	// calls and queries are the API: every method name any implementation
	// has served. The proxy keeps them so that a rollback cannot shrink it.
	calls, queries []string
}

// NewProxy returns a proxy held by the realm whose live cur is rlm, with
// first approved as its first implementation. owner approves later
// implementations, which wait delay blocks.
func NewProxy(_ int, rlm realm, owner address, delay int64, first string) *Proxy {
	p := &Proxy{u: New(owner, delay), store: NewStore(0, rlm)}
	p.u.approve(first)
	return p
}

// Register makes next the implementation and runs its Migrate. rlm is the
// proxy's live cur, so the caller must be the approved realm.
//
// Unless this is a rollback, next must answer the whole API. The check runs
// before anything changes, so a refused next leaves the proxy as it was.
func (p *Proxy) Register(_ int, rlm realm, next Impl) {
	if next == nil {
		panic("upgrade: nil implementation")
	}
	p.u.assertAcceptable(0, rlm)
	if !p.u.IsRollback() {
		calls, queries := p.Missing(next)
		if len(calls)+len(queries) > 0 {
			panic("upgrade: next implementation lacks API methods: " +
				describe(calls, queries) + "; to retire one, keep it and make it panic")
		}
	}
	from := p.u.PkgPath()
	p.u.Accept(0, rlm)
	p.impl = next
	calls, queries := next.Methods()
	p.calls, p.queries = union(p.calls, calls), union(p.queries, queries)
	next.Migrate(p.store.Begin(0, rlm), NewCustody(0, rlm), from)
}

// Call forwards a crossing call to the implementation by method name.
func (p *Proxy) Call(_ int, rlm realm, method, args string) (out string) {
	calls, _ := p.current().Methods()
	assertAnswers(method, calls, p.calls)
	p.Invoke(0, rlm, func(impl Impl, tx *Tx, c *Custody) {
		out = impl.Call(tx, c, method, args)
	})
	return out
}

// Invoke runs fn with the implementation and write handles for one crossing
// call. A proxy uses it for typed entry points that Call cannot carry, such
// as standard token functions or functions that take callbacks: fn asserts
// impl to the proxy's own interface and calls it.
//
// Coins sent with the call must be taken through tx.Sent, or the call
// panics and they go back.
//
// fn must come from the proxy realm itself, never from a caller.
func (p *Proxy) Invoke(_ int, rlm realm, fn func(impl Impl, tx *Tx, c *Custody)) {
	tx := p.store.Begin(0, rlm)
	fn(p.current(), tx, NewCustody(0, rlm))
	if !tx.sentTaken {
		for _, coin := range tx.sent() {
			if coin.Amount != 0 {
				panic(ErrUnexpectedCoins)
			}
		}
	}
}

// Current returns the implementation and a read handle, for typed read
// functions.
func (p *Proxy) Current() (Impl, View) {
	return p.current(), p.store.View()
}

func (p *Proxy) Query(method, args string) string {
	_, queries := p.current().Methods()
	assertAnswers(method, queries, p.queries)
	return p.current().Query(p.store.View(), method, args)
}

func (p *Proxy) Render(path string) string {
	return p.current().Render(p.store.View(), path)
}

// Methods returns the method names the current implementation answers
// through Call and Query. After a rollback it can be smaller than API.
func (p *Proxy) Methods() (calls, queries []string) { return p.current().Methods() }

// API returns every method name any implementation has served.
func (p *Proxy) API() (calls, queries []string) { return p.calls, p.queries }

// Missing returns the API methods next does not answer, which Register
// refuses unless it is a rollback. It changes nothing, so an
// implementation's tests can call it before the implementation is
// approved, instead of finding out once the delay has passed.
func (p *Proxy) Missing(next Impl) (calls, queries []string) {
	nextCalls, nextQueries := next.Methods()
	return minus(p.calls, nextCalls), minus(p.queries, nextQueries)
}

// Approve, Cancel, Freeze and TransferOwnership take the proxy realm's
// live cur and check its caller is the owner, so the realm forwards them
// as is, with no check of its own. See Upgrader for why the check is here.
// The realm must pass its own cur, not cur.Previous(), or the check fails.
func (p *Proxy) Approve(_ int, rlm realm, pkgPath string) { p.u.Approve(0, rlm, pkgPath) }
func (p *Proxy) Cancel(_ int, rlm realm)                  { p.u.Cancel(0, rlm) }
func (p *Proxy) Freeze(_ int, rlm realm)                  { p.u.Freeze(0, rlm) }
func (p *Proxy) TransferOwnership(_ int, rlm realm, next address) {
	p.u.TransferOwnership(0, rlm, next)
}

func (p *Proxy) Owner() address   { return p.u.Owner() }
func (p *Proxy) Frozen() bool     { return p.u.Frozen() }
func (p *Proxy) ImplPath() string { return p.u.PkgPath() }
func (p *Proxy) Approved() string { return p.u.Approved() }
func (p *Proxy) ETA() int64       { return p.u.ETA() }

func (p *Proxy) current() Impl {
	if p.impl == nil {
		panic("upgrade: no implementation registered")
	}
	return p.impl
}

// sent returns the coins that reached the proxy with this call. OriginSend
// lands on the proxy only when a user called it directly.
func (tx *Tx) sent() chain.Coins {
	if !tx.rlm.Previous().IsUserCall() {
		return nil
	}
	return unsafe.OriginSend()
}

// assertAnswers panics unless the current implementation answers method.
// A method in the API that it does not answer is one a rollback left out.
func assertAnswers(method string, current, api []string) {
	if contains(current, method) {
		return
	}
	if contains(api, method) {
		panic("upgrade: " + method + " is unavailable under the current implementation")
	}
	panic("upgrade: unknown method " + method)
}

func describe(calls, queries []string) string {
	var parts []string
	for _, m := range calls {
		parts = append(parts, "Call "+m)
	}
	for _, m := range queries {
		parts = append(parts, "Query "+m)
	}
	return strings.Join(parts, ", ")
}

// union returns a with the names in b it lacks appended.
func union(a, b []string) []string {
	for _, m := range b {
		if !contains(a, m) {
			a = append(a, m)
		}
	}
	return a
}

// minus returns the names in a that b lacks.
func minus(a, b []string) []string {
	var out []string
	for _, m := range a {
		if !contains(b, m) {
			out = append(out, m)
		}
	}
	return out
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
