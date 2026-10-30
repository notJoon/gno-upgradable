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

// Impl is the lifecycle shared by every implementation.
//
// The proxy tells implementations apart by the realm that installs them and
// the value itself, compared with ==. Use a value type such as an empty
// struct. A value holding a slice, map or func is refused, and a pointer
// compares by address, so a fresh pointer on each call never matches.
type Impl interface {
	Migrate(tx *Tx, c *Custody, from ImplRef)
}

// ImplRef identifies an implementation by the realm that installed it and the
// value it installed. Migrate receives the zero value when the proxy is first
// bootstrapped and the previous implementation on every later transition.
//
// Use Empty to recognize bootstrap, Path to branch by realm, and Is when two
// values from the same realm need different migrations. A different realm
// cannot construct a realm-declared value; if it needs to call Is for one, the
// declaring realm must export a function that returns the value.
type ImplRef struct {
	path string
	impl Impl
}

func (r ImplRef) Empty() bool  { return r.impl == nil }
func (r ImplRef) Path() string { return r.path }

// Is reports whether r names the given realm and implementation value.
func (r ImplRef) Is(path string, impl Impl) bool {
	if r.impl == nil || impl == nil {
		return false
	}
	assertComparable(impl)
	return r.path == path && r.impl == impl
}

// Method identifies one string-dispatched method and the schema its callers
// use. Schema is an opaque, stable identifier for the arguments and result.
// Changing it requires a new method name so existing callers keep working.
type Method struct {
	Name   string
	Schema string
}

// Dispatcher is the optional string interface of an implementation. Its API
// is the proxy's API: the proxy forwards every call by method name, so a later
// version can add methods without changing the proxy.
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
// A rollback is the one exception. An implementation value that served before
// from the same realm cannot know the methods added after it, so
// returning to one may leave some of the API unavailable until a version that
// has them comes back. Those methods stay in the API, so a version after the
// rollback must answer them again.
// Comparing against the current implementation instead would let an owner
// drop a method by rolling back and then upgrading.
//
// args is passed through as is. Schema names the chosen encoding.
type Dispatcher interface {
	Impl

	// Methods lists the method descriptors Call and Query answer. The proxy
	// refuses any other name before the implementation runs, and checks
	// the lists against the API when Upgrade first sees the value. Keep
	// them in step with Call and Query: nothing checks they agree, and a
	// listed name Call does not handle reaches its default case.
	//
	// The two lists are separate because moving a method from Query to
	// Call also breaks its callers.
	Methods() (calls, queries []Method)
	Call(tx *Tx, c *Custody, method, args string) string
	Query(v View, method, args string) string
}

// Renderer is the optional rendered view of an implementation.
type Renderer interface {
	Render(v View, path string) string
}

// implMeta is the method lists an implementation had when it was checked.
// The proxy routes by this copy, so a Methods that changes its answer later
// changes nothing.
type implMeta struct {
	calls, queries []Method
}

// Candidate is the declared and missing string API of an implementation.
// Empty Calls and Queries describe a typed-only implementation.
type Candidate struct {
	Calls, Queries               []Method
	MissingCalls, MissingQueries []Method
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
// realm calls Upgrade, the delay runs, and the old realm calls Upgrade again.
// So every implementation should export a crossing function that calls
// Upgrade, rather than upgrading only from init, which never runs twice.
//
// The delay applies to rollbacks on purpose. Users accepted the old code
// against older state, and some may have left because of it. An instant
// rollback would let the owner put that code back before they can react.
//
// The old implementation usually lacks methods the newer one added. They
// report as unavailable until a version that has them is back. See Dispatcher.
//
// Rolling back changes code, not state:
//   - The old implementation's Migrate runs with from set to the newer
//     implementation, and must accept it. A Migrate that allows only specific
//     predecessors blocks the rollback.
//   - Tables the newer version added stay in the Store. The old version
//     ignores them, and rolling forward again finds them intact.
//   - Rows the newer version rewrote must still be readable by the old one.
//     A version that changes a row's format in place makes rolling back
//     unsafe, so prefer adding a new table.
//   - Coins stay at the proxy's address throughout.
type Proxy struct {
	u       *upgrader
	store   *Store
	impl    Impl
	pending Impl

	// calls and queries are the API: every method name any implementation
	// has served. The proxy keeps them so that a rollback cannot shrink it.
	calls, queries []Method

	activeMeta, pendingMeta implMeta
	served                  []ImplRef
}

// NewProxy returns an empty proxy held by the realm whose live cur is rlm.
// The owner must approve the first implementation only after its realm is
// deployed, because it installs without a delay. Later ones wait delay blocks.
func NewProxy(_ int, rlm realm, owner address, delay int64) *Proxy {
	return &Proxy{u: newUpgrader(0, rlm, owner, delay), store: NewStore(0, rlm)}
}

// Upgrade moves the pending approval forward. rlm is the proxy's live cur, so
// the caller must be the approved realm, and the realm calls it the same way
// every time:
//   - With nothing live, next becomes the implementation at once.
//   - Otherwise the first call saves next and starts the delay. It checks next
//     against the API as installing will, so an implementation that lacks a
//     method fails now rather than once the delay has passed.
//   - A call after the delay installs the saved value and runs its Migrate.
//     next must equal it.
//
// Unless the same realm installed next before, it must answer the whole API.
func (p *Proxy) Upgrade(_ int, rlm realm, next Impl) {
	if p.impl != nil && p.pending == nil {
		p.prepare(0, rlm, next)
		return
	}
	p.u.assertAcceptable(0, rlm)
	meta := p.pendingMeta
	if p.pending == nil {
		meta = inspectMeta(next)
		p.assertAPI(meta, false)
	} else if next != p.pending {
		panic("upgrade: next is not the prepared implementation")
	}
	path := p.u.Approved()
	rollback := p.isRollback(path, next)
	from := ImplRef{path: p.u.PkgPath(), impl: p.impl}
	p.u.accept(0, rlm, rollback)
	p.impl, p.activeMeta = next, meta
	p.clearPending()
	p.calls = union(p.calls, meta.calls)
	p.queries = union(p.queries, meta.queries)
	if !rollback {
		p.served = append(p.served, ImplRef{path: path, impl: next})
	}
	c := NewCustody(0, rlm)
	next.Migrate(p.store.Begin(0, rlm), c, from)
	c.revokeApprovals()
}

func (p *Proxy) prepare(_ int, rlm realm, next Impl) {
	p.u.assertPreparable(0, rlm)
	meta := inspectMeta(next)
	rollback := p.isRollback(p.u.Approved(), next)
	p.assertAPI(meta, rollback)
	p.u.prepare(0, rlm, "rollback", strconv.FormatBool(rollback))
	p.pending, p.pendingMeta = next, meta
}

// assertAPI panics unless meta answers the whole API or this is a rollback.
// An implementation that is not a Dispatcher answers no methods.
func (p *Proxy) assertAPI(meta implMeta, rollback bool) {
	if rollback {
		return
	}
	calls, queries := minus(p.calls, meta.calls), minus(p.queries, meta.queries)
	if len(calls)+len(queries) > 0 {
		panic("upgrade: next implementation lacks API methods: " +
			describe(calls, queries) + "; to retire one, keep it and make it panic")
	}
}

// Call forwards a crossing call to the implementation by method name.
func (p *Proxy) Call(_ int, rlm realm, method, args string) (out string) {
	p.current()
	assertAnswers(method, p.activeMeta.calls, p.calls)
	p.Invoke(0, rlm, func(impl Impl, tx *Tx, c *Custody) {
		out = impl.(Dispatcher).Call(tx, c, method, args)
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
	c.revokeApprovals()
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
	impl := p.current()
	assertAnswers(method, p.activeMeta.queries, p.queries)
	return impl.(Dispatcher).Query(p.store.View(), method, args)
}

// Render puts a banner for a pending upgrade or a freeze above the
// implementation's output. The proxy writes it, so no implementation can
// hide an upgrade users should see coming. An implementation that is not a
// Renderer gets the banner alone.
func (p *Proxy) Render(path string) string {
	renderer, ok := p.current().(Renderer)
	banner := p.banner()
	if !ok {
		return banner
	}
	return banner + renderer.Render(p.store.View(), path)
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
	if p.pending != nil && p.isRollback(u.approved, p.pending) {
		kind = "Rollback"
	}
	if !u.prepared {
		return "> [!WARNING]\n> " + kind + " approved: `" + u.approved + "`. Its delay of " +
			strconv.FormatInt(u.delay, 10) + " blocks starts when it calls Upgrade.\n\n"
	}
	return "> [!WARNING]\n> " + kind + " pending: `" + u.approved + "` can take over at block " +
		strconv.FormatInt(u.eta, 10) + ".\n\n"
}

// Methods returns the method descriptors the current implementation answers
// through Call and Query. After a rollback it can be smaller than API.
func (p *Proxy) Methods() (calls, queries []Method) {
	p.current()
	return p.activeMeta.calls, p.activeMeta.queries
}

// API returns every method descriptor any implementation has served.
func (p *Proxy) API() (calls, queries []Method) { return p.calls, p.queries }

// InspectImpl checks next exactly as Upgrade does and returns its declared
// string API and the methods it lacks from the proxy's API. It changes no
// proxy state. The candidate's realm path is authenticated only by Upgrade,
// so inspection cannot determine whether it is a rollback.
func (p *Proxy) InspectImpl(next Impl) Candidate {
	meta := inspectMeta(next)
	return Candidate{
		Calls:          meta.calls,
		Queries:        meta.queries,
		MissingCalls:   minus(p.calls, meta.calls),
		MissingQueries: minus(p.queries, meta.queries),
	}
}

// Missing returns the API methods next does not answer, which Upgrade
// refuses unless it is a rollback. It changes nothing, so an
// implementation's tests can call it before the implementation is
// approved, instead of finding out once the delay has passed.
func (p *Proxy) Missing(next Impl) (calls, queries []Method) {
	candidate := p.InspectImpl(next)
	return candidate.MissingCalls, candidate.MissingQueries
}

// Approve, Cancel, Freeze and TransferOwnership take the proxy realm's
// live cur and check its caller is the owner, so the realm forwards them
// as is, with no check of its own. The realm must pass its own cur, not
// cur.Previous(), or the check fails. Approve, Cancel and Freeze also drop
// a value saved by Upgrade.
func (p *Proxy) Approve(_ int, rlm realm, pkgPath string) {
	p.u.Approve(0, rlm, pkgPath)
	p.clearPending()
}

func (p *Proxy) Cancel(_ int, rlm realm) {
	p.u.Cancel(0, rlm)
	p.clearPending()
}

func (p *Proxy) Freeze(_ int, rlm realm) {
	p.u.Freeze(0, rlm)
	p.clearPending()
}

func (p *Proxy) TransferOwnership(_ int, rlm realm, next address) {
	p.u.TransferOwnership(0, rlm, next)
}
func (p *Proxy) AcceptOwnership(_ int, rlm realm) { p.u.AcceptOwnership(0, rlm) }

func (p *Proxy) Owner() address        { return p.u.Owner() }
func (p *Proxy) PendingOwner() address { return p.u.PendingOwner() }
func (p *Proxy) Frozen() bool          { return p.u.Frozen() }
func (p *Proxy) Approved() string      { return p.u.Approved() }

// ImplPath returns the realm that installed the current implementation. That
// realm need not declare the value's type, so audit both.
func (p *Proxy) ImplPath() string { return p.u.PkgPath() }

// ETA returns the first height at which the approved realm can install. It
// stays 0 until that realm's first Upgrade call starts the delay, except for
// the first implementation, which needs none.
func (p *Proxy) ETA() int64 { return p.u.ETA() }

func (p *Proxy) current() Impl {
	if p.impl == nil {
		panic("upgrade: no implementation installed")
	}
	return p.impl
}

func (p *Proxy) clearPending() {
	p.pending = nil
	p.pendingMeta = implMeta{}
}

// isRollback reports whether the realm at path has installed next before.
// Matching the value alone is not enough: another realm can declare a zero
// value of an exported implementation type. inspectMeta has checked every
// value here is comparable.
func (p *Proxy) isRollback(path string, next Impl) bool {
	for _, s := range p.served {
		if s.path == path && s.impl == next {
			return true
		}
	}
	return false
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
func assertAnswers(method string, current, api []Method) {
	if containsName(current, method) {
		return
	}
	if containsName(api, method) {
		panic("upgrade: " + method + " is unavailable under the current implementation")
	}
	panic("upgrade: unknown method " + method)
}

func describe(calls, queries []Method) string {
	var parts []string
	for _, m := range calls {
		parts = append(parts, "Call "+m.Name+" ["+m.Schema+"]")
	}
	for _, m := range queries {
		parts = append(parts, "Query "+m.Name+" ["+m.Schema+"]")
	}
	return strings.Join(parts, ", ")
}

// union returns a with the names in b it lacks appended.
func union(a, b []Method) []Method {
	for _, m := range b {
		if !containsMethod(a, m) {
			a = append(a, m)
		}
	}
	return a
}

// minus returns the names in a that b lacks.
func minus(a, b []Method) []Method {
	var out []Method
	for _, m := range a {
		if !containsMethod(b, m) {
			out = append(out, m)
		}
	}
	return out
}

func containsMethod(list []Method, method Method) bool {
	for _, v := range list {
		if v == method {
			return true
		}
	}
	return false
}

func containsName(list []Method, name string) bool {
	for _, v := range list {
		if v.Name == name {
			return true
		}
	}
	return false
}

// inspectMeta checks impl and copies its method lists.
func inspectMeta(impl Impl) implMeta {
	if impl == nil {
		panic("upgrade: nil implementation")
	}
	assertComparable(impl)
	var meta implMeta
	if d, ok := impl.(Dispatcher); ok {
		calls, queries := d.Methods()
		validateMethods(calls, queries)
		meta.calls, meta.queries = cloneMethods(calls), cloneMethods(queries)
	}
	return meta
}

// assertComparable panics unless impl can be compared with ==, which is how
// the proxy recognizes a rollback and the prepared value.
func assertComparable(impl Impl) {
	defer func() {
		if recover() != nil {
			panic("upgrade: implementation must be comparable")
		}
	}()
	_ = impl == impl
}

func cloneMethods(methods []Method) []Method {
	var cloned []Method
	return append(cloned, methods...)
}

func validateMethods(calls, queries []Method) {
	validateMethodList("Call", calls)
	validateMethodList("Query", queries)
}

func validateMethodList(kind string, methods []Method) {
	for i, method := range methods {
		if method.Name == "" || method.Schema == "" || len(method.Name) > 128 || len(method.Schema) > 256 {
			panic("upgrade: invalid " + kind + " method")
		}
		for j := 0; j < i; j++ {
			if methods[j].Name == method.Name {
				panic("upgrade: duplicate " + kind + " method " + method.Name)
			}
		}
	}
}
