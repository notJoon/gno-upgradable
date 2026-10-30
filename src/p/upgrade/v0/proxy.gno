package upgrade

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

const (
	ErrReentrant       = "upgrade: reentrant call"
	ErrUnexpectedCoins = "upgrade: method did not take the coins sent with it"
)

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
// ordinary upgrade to it: the owner approves the old realm's path, the old
// realm calls Prepare, the delay runs, and the old realm registers again. So
// every implementation should export crossing functions that call Prepare
// and Register, such as Prepare and Activate, rather than registering only
// from init, which never runs twice.
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
	u       *Upgrader
	store   *Store
	impl    Impl
	pending Impl

	// calls and queries are the API: every method name any implementation
	// has served. The proxy keeps them so that a rollback cannot shrink it.
	calls, queries []string
}

// NewProxy returns a proxy held by the realm whose live cur is rlm, with
// first approved as its first implementation. owner approves later
// implementations, which wait delay blocks.
func NewProxy(_ int, rlm realm, owner address, delay int64, first string) *Proxy {
	p := &Proxy{u: New(0, rlm, owner, delay), store: NewStore(0, rlm)}
	p.u.approve(first)
	return p
}

// Bootstrap installs the first implementation without a delay. rlm is the
// proxy's live cur, so the caller must be the first approved realm.
func (p *Proxy) Bootstrap(_ int, rlm realm, first Impl) {
	if p.impl != nil {
		panic("upgrade: implementation already registered")
	}
	p.u.assertAcceptable(0, rlm)
	p.assertAPI(first)
	p.install(0, rlm, first)
}

// Register installs the implementation saved by Prepare and runs its Migrate.
// rlm is the proxy's live cur, so the caller must be the approved realm.
//
// Unless this is a rollback, the pending implementation must answer the whole
// API. The check runs before anything changes.
func (p *Proxy) Register(_ int, rlm realm) {
	p.u.assertAcceptable(0, rlm)
	if p.pending == nil {
		panic("upgrade: no prepared implementation")
	}
	p.assertAPI(p.pending)
	p.install(0, rlm, p.pending)
}

func (p *Proxy) install(_ int, rlm realm, next Impl) {
	from := p.u.PkgPath()
	p.u.Accept(0, rlm)
	p.impl, p.pending = next, nil
	calls, queries := next.Methods()
	p.calls, p.queries = union(p.calls, calls), union(p.queries, queries)
	c := NewCustody(0, rlm)
	next.Migrate(p.store.Begin(0, rlm), c, from)
	c.close()
}

// Prepare starts the delay of the pending approval. rlm is the proxy's live
// cur, so the caller must be the approved realm. It checks next against the
// API as Register will, so an implementation that lacks a method fails now
// rather than once the delay has passed.
func (p *Proxy) Prepare(_ int, rlm realm, next Impl) {
	p.u.assertPreparable(0, rlm)
	p.assertAPI(next)
	p.u.Prepare(0, rlm)
	p.pending = next
}

// assertAPI panics unless next answers the whole API or this is a rollback.
func (p *Proxy) assertAPI(next Impl) {
	if next == nil {
		panic("upgrade: nil implementation")
	}
	if p.u.IsRollback() {
		return
	}
	calls, queries := p.Missing(next)
	if len(calls)+len(queries) > 0 {
		panic("upgrade: next implementation lacks API methods: " +
			describe(calls, queries) + "; to retire one, keep it and make it panic")
	}
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
	c := NewCustody(0, rlm)
	fn(p.current(), tx, c)
	c.close()
	if !tx.sentTaken {
		for _, coin := range tx.sent() {
			if coin.Amount != 0 {
				panic(ErrUnexpectedCoins)
			}
		}
	}
}

// Inspect runs fn with the current implementation and a read handle so a typed
// proxy entry point can keep its reentrancy guard around the whole read.
func (p *Proxy) Inspect(fn func(impl Impl, v View)) {
	fn(p.current(), p.store.View())
}

func (p *Proxy) Query(method, args string) string {
	_, queries := p.current().Methods()
	assertAnswers(method, queries, p.queries)
	return p.current().Query(p.store.View(), method, args)
}

// Render puts a banner for a pending upgrade or a freeze above the
// implementation's output. The proxy writes it, so no implementation can
// hide an upgrade users should see coming.
func (p *Proxy) Render(path string) string {
	return p.banner() + p.current().Render(p.store.View(), path)
}

// banner needs no escaping: approve allows only package path characters.
func (p *Proxy) banner() string {
	u := p.u
	if u.frozen {
		return "> [!NOTE]\n> Upgrades are frozen. `" + u.pkgPath + "` serves for good.\n\n"
	}
	if u.approved == "" {
		return ""
	}
	kind := "Upgrade"
	if u.IsRollback() {
		kind = "Rollback"
	}
	if !u.prepared {
		return "> [!WARNING]\n> " + kind + " approved: `" + u.approved + "`. Its delay of " +
			strconv.FormatInt(u.delay, 10) + " blocks starts when it calls Prepare.\n\n"
	}
	return "> [!WARNING]\n> " + kind + " pending: `" + u.approved + "` can take over at block " +
		strconv.FormatInt(u.eta, 10) + ".\n\n"
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
func (p *Proxy) Approve(_ int, rlm realm, pkgPath string) {
	p.u.Approve(0, rlm, pkgPath)
	p.pending = nil
}

func (p *Proxy) Cancel(_ int, rlm realm) {
	p.u.Cancel(0, rlm)
	p.pending = nil
}

func (p *Proxy) Freeze(_ int, rlm realm) {
	p.u.Freeze(0, rlm)
	p.pending = nil
}

func (p *Proxy) TransferOwnership(_ int, rlm realm, next address) {
	p.u.TransferOwnership(0, rlm, next)
}
func (p *Proxy) AcceptOwnership(_ int, rlm realm) { p.u.AcceptOwnership(0, rlm) }

func (p *Proxy) Owner() address        { return p.u.Owner() }
func (p *Proxy) PendingOwner() address { return p.u.PendingOwner() }
func (p *Proxy) Frozen() bool          { return p.u.Frozen() }
func (p *Proxy) ImplPath() string      { return p.u.PkgPath() }
func (p *Proxy) Approved() string      { return p.u.Approved() }
func (p *Proxy) ETA() int64            { return p.u.ETA() }

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
