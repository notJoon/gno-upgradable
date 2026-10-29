package upgrade

import (
	"chain"
	"chain/runtime/unsafe"
)

const ErrUnexpectedCoins = "upgrade: method did not take the coins sent with it"

// Impl is what an implementation realm provides. Its API is the proxy's
// API: the proxy forwards every call by method name, so a later version can
// add methods without changing the proxy.
//
// args is passed through as is. Each implementation chooses its encoding.
type Impl interface {
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
type Proxy struct {
	u     *Upgrader
	store *Store
	impl  Impl
}

// NewProxy returns a proxy owned by the realm whose live cur is rlm, with
// first approved as its first implementation. Later approvals wait delay
// blocks.
func NewProxy(_ int, rlm realm, delay int64, first string) *Proxy {
	p := &Proxy{u: New(delay), store: NewStore(0, rlm)}
	p.u.Approve(first)
	return p
}

// Register makes next the implementation and runs its Migrate. rlm is the
// proxy's live cur, so the caller must be the approved realm.
func (p *Proxy) Register(_ int, rlm realm, next Impl) {
	if next == nil {
		panic("upgrade: nil implementation")
	}
	from := p.u.PkgPath()
	p.u.Accept(0, rlm)
	p.impl = next
	next.Migrate(p.store.Begin(0, rlm), NewCustody(0, rlm), from)
}

// Call forwards a crossing call to the implementation. Coins sent with the
// call must be taken through tx.Sent, or the call panics and they go back.
func (p *Proxy) Call(_ int, rlm realm, method, args string) string {
	tx := p.store.Begin(0, rlm)
	out := p.current().Call(tx, NewCustody(0, rlm), method, args)
	if !tx.sentTaken {
		for _, coin := range tx.sent() {
			if coin.Amount != 0 {
				panic(ErrUnexpectedCoins)
			}
		}
	}
	return out
}

func (p *Proxy) Query(method, args string) string {
	return p.current().Query(p.store.View(), method, args)
}

func (p *Proxy) Render(path string) string {
	return p.current().Render(p.store.View(), path)
}

func (p *Proxy) Approve(pkgPath string) { p.u.Approve(pkgPath) }
func (p *Proxy) Cancel()                { p.u.Cancel() }
func (p *Proxy) ImplPath() string       { return p.u.PkgPath() }
func (p *Proxy) Approved() string       { return p.u.Approved() }
func (p *Proxy) ETA() int64             { return p.u.ETA() }

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
