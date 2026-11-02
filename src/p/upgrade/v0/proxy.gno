package upgrade

import (
	"chain"
	"chain/runtime"
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
	if impl == nil || r.path != path {
		return false
	}
	assertComparable(impl)
	return r.impl == impl
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

// Upgrade moves the pending approval forward. rlm is the proxy's live cur, so
// the caller must be the approved realm, and the realm calls it the same way
// every time:
//   - With nothing live, next becomes the implementation at once.
//   - Otherwise the first call saves next and starts the delay. It checks next
//     against the API as installing will, so an implementation that lacks a
//     method fails now rather than once the delay has passed.
//   - A call after the delay and within the window installs the saved value
//     and runs its Migrate. next must equal it.
//
// Unless the same realm installed next before, it must answer the whole API.
func (p *Proxy) Upgrade(_ int, rlm realm, next Impl) {
	path := p.assertApproved(0, rlm)
	var meta implMeta
	switch {
	case p.impl == nil:
		// The API is empty until the first install, so there is nothing to check.
		meta = inspectMeta(next)
	case p.pending == nil:
		p.prepare(path, next)
		return
	default:
		if next != p.pending {
			panic("upgrade: next is not the prepared implementation")
		}
		p.assertInstallable()
		meta = p.pendingMeta
	}
	rollback := p.isRollback(path, next)
	from := ImplRef{path: p.implPath, impl: p.impl}
	p.emit("Upgraded", "from", p.implPath, "to", path, "rollback", strconv.FormatBool(rollback))
	p.implPath, p.impl, p.activeMeta = path, next, meta
	p.clearApproval()
	p.calls = union(p.calls, meta.calls)
	p.queries = union(p.queries, meta.queries)
	if !rollback {
		p.served = append(p.served, ImplRef{path: path, impl: next})
	}
	c := NewCustody(0, rlm)
	next.Migrate(p.store.Begin(0, rlm), c, from)
	c.revokeApprovals()
}

// prepare saves next and starts its delay. It runs once per approval, so a
// later call cannot push the ETA back.
func (p *Proxy) prepare(path string, next Impl) {
	meta := inspectMeta(next)
	rollback := p.isRollback(path, next)
	p.assertAPI(meta, rollback)
	p.eta = addDelay(runtime.ChainHeight(), p.delay)
	addDelay(p.eta, p.window) // so assertInstallable and banner need no check
	p.pending, p.pendingMeta = next, meta
	p.emit("UpgradePrepared", "pkgPath", path, "eta", strconv.FormatInt(p.eta, 10),
		"rollback", strconv.FormatBool(rollback))
}

// assertAPI panics unless meta answers the whole API or this is a rollback.
// An implementation that is not a Dispatcher answers no methods.
func (p *Proxy) assertAPI(meta implMeta, rollback bool) {
	if rollback {
		return
	}
	calls, queries := p.missing(meta)
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
// It runs only with an implementation live, because Render needs one.
func (p *Proxy) banner() string {
	if p.frozen {
		return "> [!NOTE]\n> Upgrades are frozen. `" + p.implPath + "` serves for good.\n\n"
	}
	if p.approved == "" {
		return ""
	}
	kind := "Upgrade"
	if p.pending != nil && p.isRollback(p.approved, p.pending) {
		kind = "Rollback"
	}
	if p.pending == nil {
		return "> [!WARNING]\n> " + kind + " approved: `" + p.approved + "`. Its delay of " +
			strconv.FormatInt(p.delay, 10) + " blocks starts when it calls Upgrade.\n\n"
	}
	end := p.eta + p.window
	if runtime.ChainHeight() > end {
		return "> [!NOTE]\n> " + kind + " to `" + p.approved + "` expired at block " +
			strconv.FormatInt(end, 10) + ". It cannot land unless the owner approves it again.\n\n"
	}
	return "> [!WARNING]\n> " + kind + " pending: `" + p.approved + "` can take over from block " +
		strconv.FormatInt(p.eta, 10) + " until block " + strconv.FormatInt(end, 10) + ".\n\n"
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
	calls, queries := p.missing(meta)
	return Candidate{
		Calls:          meta.calls,
		Queries:        meta.queries,
		MissingCalls:   calls,
		MissingQueries: queries,
	}
}

// missing returns the API methods meta does not answer.
func (p *Proxy) missing(meta implMeta) (calls, queries []Method) {
	return minus(p.calls, meta.calls), minus(p.queries, meta.queries)
}

func (p *Proxy) current() Impl {
	if p.impl == nil {
		panic("upgrade: no implementation installed")
	}
	return p.impl
}

// isRollback reports whether the realm at path has installed next before.
// Matching the value alone is not enough: another realm can declare a zero
// value of an exported implementation type.
func (p *Proxy) isRollback(path string, next Impl) bool {
	for _, s := range p.served {
		if s.Is(path, next) {
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
