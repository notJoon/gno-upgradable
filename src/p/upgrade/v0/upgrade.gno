package upgrade

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
)

const (
	ErrInvalidPath     = "upgrade: approved path must be a realm path without a subpath"
	ErrSpoofedRealm    = "upgrade: realm must be the proxy's live current realm"
	ErrNotApproved     = "upgrade: caller is not the approved implementation"
	ErrTooEarly        = "upgrade: approval is still in its delay"
	ErrExpired         = "upgrade: approval expired, the owner must approve again"
	ErrUnauthorized    = "upgrade: caller is not the owner"
	ErrFrozen          = "upgrade: upgrades are frozen"
	ErrDelayOverflow   = "upgrade: delay overflows ETA"
	ErrNotPendingOwner = "upgrade: caller is not the pending owner"
)

// Proxy is the state of an upgradable realm: who may become its
// implementation, its Store, and the live implementation. The realm creates
// it from init, keeps it in an unexported variable, and forwards its
// crossing functions to it.
//
// # Delay and window
//
// Once an implementation is live, an approval can be accepted only delay
// blocks after the approved realm first calls Upgrade, so users can read the
// code and leave first. The delay starts at that call, not at the approval,
// because a path can be approved before anything is deployed there. Counting
// from the approval would let the code appear in the last block of the delay.
// The first implementation has no delay because there is nothing to protect
// yet.
//
// The install must then happen within window blocks of the ETA. Users judged
// the code when the delay started, and a prepared upgrade that could land at
// any later time would keep them watching forever. After the window the
// owner must approve again, which restarts the whole delay.
//
// # Owner
//
// Only the owner may approve, cancel or freeze. The owner is the address
// that called the realm holding the proxy: a user, or a realm such as a DAO
// acting at its own address.
//
// The owner check lives here, not in the holding realm, so a forwarding
// function cannot leave it out. A realm that forgot its own admin check would
// let anyone schedule any upgrade, and the delay helps only if someone
// notices in time.
//
// The owner is an address rather than a realm path because one comparison
// then covers both a user and a governance realm, and it avoids the trap of
// matching a path against a user call, whose path is empty.
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
	realm         string // the holding realm, named in every event
	owner         address
	pendingOwner  address
	delay, window int64
	frozen        bool
	store         *Store

	// The live implementation and the realm that installed it.
	implPath   string
	impl       Impl
	activeMeta implMeta

	// The pending upgrade. pending is set once the approved realm has called
	// Upgrade and its delay has started. eta is the first height at which it
	// may install. Only clearApproval resets these.
	approved    string
	eta         int64
	pending     Impl
	pendingMeta implMeta

	// calls and queries are the API: every method name any implementation
	// has served. The proxy keeps them so that a rollback cannot shrink it.
	calls, queries []Method
	served         []ImplRef
}

// NewProxy returns an empty proxy held by the realm whose live cur is rlm.
// The owner must approve the first implementation only after its realm is
// deployed, because it installs without a delay. Later ones wait delay blocks
// and must then install within window blocks.
func NewProxy(_ int, rlm realm, owner address, delay, window int64) *Proxy {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}
	if !owner.IsValid() {
		panic("upgrade: invalid owner")
	}
	if delay < 0 {
		panic("upgrade: negative delay")
	}
	if window <= 0 {
		panic("upgrade: window must be positive")
	}
	// prepare adds both to the chain height, so a sum that overflows here
	// would refuse every upgrade after the first.
	addDelay(delay, window)
	return &Proxy{
		realm:  rlm.PkgPath(),
		owner:  owner,
		delay:  delay,
		window: window,
		store:  NewStore(0, rlm),
	}
}

// Approve, Cancel, Freeze and TransferOwnership take the proxy realm's
// live cur and check its caller is the owner, so the realm forwards them
// as is, with no check of its own. The realm must pass its own cur, not
// cur.Previous(), or the check fails.

// Approve lets the realm at pkgPath become the next implementation,
// replacing any pending approval and any value it saved.
func (p *Proxy) Approve(_ int, rlm realm, pkgPath string) {
	p.assertOwner(0, rlm)
	p.approve(pkgPath)
}

// approve applies an approval after the exported caller has performed its
// authorization check. Keeping validation and state changes here also lets
// package tests exercise path and delay rules directly.
func (p *Proxy) approve(pkgPath string) {
	if p.frozen {
		panic(ErrFrozen)
	}
	// pkgPath must look like `<domain>/r/<path>` and must not name a subrealm.
	// This only catches typos. The real gate is assertApproved, which compares
	// the approval with the calling realm's path, and no deployed realm can
	// match a malformed one.
	parts := strings.SplitN(pkgPath, "/", 3)
	_, _, isSub := chain.SplitPkgSubPath(pkgPath)
	if len(parts) != 3 || parts[0] == "" || parts[1] != "r" || parts[2] == "" || isSub {
		panic(ErrInvalidPath)
	}
	// Only characters a package path can hold, which also keeps the path
	// safe to print in the proxy's Render banner.
	if !onlyChars(pkgPath, "./_-") {
		panic(ErrInvalidPath)
	}
	p.clearApproval()
	p.approved = pkgPath
	// With nothing live there is no delay, so the approval is ready at once.
	if p.impl == nil {
		p.eta = runtime.ChainHeight()
	}
	p.emit("UpgradeApproved", "pkgPath", pkgPath, "eta", strconv.FormatInt(p.eta, 10))
}

// Cancel drops the pending approval, if any. Owner only.
func (p *Proxy) Cancel(_ int, rlm realm) {
	p.assertOwner(0, rlm)
	if p.approved == "" {
		return
	}
	p.emit("UpgradeCancelled", "pkgPath", p.approved)
	p.clearApproval()
}

// Freeze ends upgrades for good, dropping any pending approval. The current
// implementation keeps serving and nothing can replace it, so users can
// trust its code rather than its owner. There is no way back. Owner only.
//
// There is no Unfreeze on purpose: a freeze that can be undone gives users
// nothing they can rely on. Freeze is also the only way to give up the power
// to upgrade. Renouncing the owner instead would also disable the admin
// methods that implementations gate on Owner, such as collecting fees.
func (p *Proxy) Freeze(_ int, rlm realm) {
	p.assertOwner(0, rlm)
	// Freezing before any implementation is live would leave the realm
	// unable to answer any call, forever.
	if p.impl == nil {
		panic("upgrade: nothing to freeze before the first implementation")
	}
	// Clearing the approval is what stops a pending upgrade from landing
	// after the freeze. Upgrade needs no frozen check of its own, because it
	// refuses when nothing is approved and approve refuses once frozen.
	p.clearApproval()
	p.frozen = true
	p.emit("UpgradeFrozen", "pkgPath", p.implPath)
}

// TransferOwnership nominates next to accept the owner role. It still works
// after Freeze, because implementations may gate their own admin methods on
// Owner. Owner only.
//
// The current owner keeps control until next calls AcceptOwnership, preventing
// a valid but mistyped address from making the role unreachable.
func (p *Proxy) TransferOwnership(_ int, rlm realm, next address) {
	p.assertOwner(0, rlm)
	if !next.IsValid() {
		panic("upgrade: invalid owner")
	}
	p.pendingOwner = next
	p.emit("OwnershipTransferStarted", "from", p.owner.String(), "to", next.String())
}

// AcceptOwnership completes a pending transfer. The caller must be the
// nominated address acting as a user or realm.
func (p *Proxy) AcceptOwnership(_ int, rlm realm) {
	p.assertHolder(0, rlm)
	if !p.pendingOwner.IsValid() || rlm.Previous().Address() != p.pendingOwner {
		panic(ErrNotPendingOwner)
	}
	from := p.owner
	p.owner, p.pendingOwner = p.pendingOwner, ""
	p.emit("OwnershipTransferred", "from", from.String(), "to", p.owner.String())
}

func (p *Proxy) clearApproval() {
	p.approved, p.eta = "", 0
	p.pending, p.pendingMeta = nil, implMeta{}
}

// assertInstallable panics unless the saved value may install now: its delay
// has passed and its window has not.
func (p *Proxy) assertInstallable() {
	h := runtime.ChainHeight()
	if h < p.eta {
		panic(ErrTooEarly)
	}
	// prepare checked that eta+window does not overflow.
	if h >= p.eta+p.window {
		panic(ErrExpired)
	}
}

func addDelay(height, delay int64) int64 {
	const maxInt64 = 1<<63 - 1
	if delay > maxInt64-height {
		panic(ErrDelayOverflow)
	}
	return height + delay
}

// assertOwner panics unless rlm is the holding realm's live cur and its
// caller is the owner. IsCurrent comes first because a realm value whose
// frame has returned still reports that frame's Previous, so a value handed
// out during the owner's call could otherwise pass for the owner later.
func (p *Proxy) assertOwner(_ int, rlm realm) {
	p.assertHolder(0, rlm)
	if rlm.Previous().Address() != p.owner {
		panic(ErrUnauthorized)
	}
}

// assertApproved panics unless rlm is the holding realm's live cur and its
// caller is the approved realm, and returns the caller's path.
func (p *Proxy) assertApproved(_ int, rlm realm) string {
	p.assertHolder(0, rlm)
	caller := rlm.Previous().PkgPath()
	// A user caller has empty package path,
	// so an empty approval must not match.
	if p.approved == "" || caller != p.approved {
		panic(ErrNotApproved)
	}
	return caller
}

// assertHolder panics unless rlm is the holding realm's live cur.
func (p *Proxy) assertHolder(_ int, rlm realm) {
	if !rlm.IsCurrent() || rlm.PkgPath() != p.realm {
		panic(ErrSpoofedRealm)
	}
}

// emit emits an event with a "realm" attribute naming the holding realm.
// The event's pkg_path is this library's, shared by every holding realm.
func (p *Proxy) emit(typ string, attrs ...string) {
	chain.Emit(typ, append([]string{"realm", p.realm}, attrs...)...)
}

func (p *Proxy) Owner() address        { return p.owner }
func (p *Proxy) PendingOwner() address { return p.pendingOwner }
func (p *Proxy) Frozen() bool          { return p.frozen }

// Approved returns the pending approval, or empty string if there is none.
func (p *Proxy) Approved() string { return p.approved }

// ImplPath returns the realm that installed the current implementation, or
// empty string before the first one. That realm need not declare the value's
// type, so audit both.
func (p *Proxy) ImplPath() string { return p.implPath }

// ETA returns the first height at which the approved realm can install. It
// stays 0 until that realm's first Upgrade call starts the delay, except for
// the first implementation, which needs none.
func (p *Proxy) ETA() int64 { return p.eta }

// onlyChars reports whether s holds only lowercase letters, digits and extra.
func onlyChars(s, extra string) bool {
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.ContainsRune(extra, c)) {
			return false
		}
	}
	return true
}
