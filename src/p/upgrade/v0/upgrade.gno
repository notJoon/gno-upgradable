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
	ErrUnauthorized    = "upgrade: caller is not the owner"
	ErrFrozen          = "upgrade: upgrades are frozen"
	ErrNotPrepared     = "upgrade: approved implementation has not called Upgrade"
	ErrPrepared        = "upgrade: approval is already prepared"
	ErrDelayOverflow   = "upgrade: delay overflows ETA"
	ErrNotPendingOwner = "upgrade: caller is not the pending owner"
)

// upgrader records the path of a proxy realm's current implementation and
// the one approved to replace it. Proxy holds one and keeps the values.
//
// Once an implementation is live, an approval can be accepted only delay
// blocks after the approved realm first calls Upgrade, so users can read the
// code and leave first. The delay starts at that call, not at the approval, because
// a path can be approved before anything is deployed there. Counting from
// the approval would let the code appear in the last block of the delay.
// The first implementation has no delay because there is nothing to protect
// yet.
//
// Only the owner may approve, cancel or freeze. The owner is the address
// that called the realm holding the upgrader: a user, or a realm such as a
// DAO acting at its own address.
//
// The owner check lives here, not in the holding realm, so a forwarding
// function cannot leave it out. A realm that forgot its own admin check would
// let anyone schedule any upgrade, and the delay helps only if someone
// notices in time.
//
// The owner is an address rather than a realm path because one comparison
// then covers both a user and a governance realm, and it avoids the trap of
// matching a path against a user call, whose path is empty.
type upgrader struct {
	realm        string // the holding realm, named in every event
	owner        address
	pendingOwner address
	delay        int64
	pkgPath      string
	approved     string
	eta          int64 // first height at which approved may be accepted
	prepared     bool  // eta is set: the delay started, or no delay was due
	frozen       bool
}

// newUpgrader returns an upgrader held by the realm whose live cur is rlm,
// owned by owner, whose approvals wait delay blocks.
func newUpgrader(_ int, rlm realm, owner address, delay int64) *upgrader {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}
	if !owner.IsValid() {
		panic("upgrade: invalid owner")
	}
	if delay < 0 {
		panic("upgrade: negative delay")
	}
	return &upgrader{realm: rlm.PkgPath(), owner: owner, delay: delay}
}

// Approve lets the realm at pkgPath become the next implementation,
// replacing any pending approval. rlm is the holding realm's live cur, and
// its caller must be the owner.
func (u *upgrader) Approve(_ int, rlm realm, pkgPath string) {
	u.assertOwner(0, rlm)
	u.approve(pkgPath)
}

// approve applies an approval after the exported caller has performed its
// authorization check. Keeping validation and state changes here also lets
// package tests exercise path and delay rules directly.
func (u *upgrader) approve(pkgPath string) {
	if u.frozen {
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
	u.approved = pkgPath
	// With nothing live there is no delay, so the approval is ready at once.
	// eta alone cannot mark this: init runs at height 0 on a genesis chain.
	u.eta, u.prepared = 0, u.pkgPath == ""
	if u.prepared {
		u.eta = runtime.ChainHeight()
	}
	u.emit("UpgradeApproved", "pkgPath", pkgPath, "eta", strconv.FormatInt(u.eta, 10))
}

// Cancel drops the pending approval, if any. Owner only.
func (u *upgrader) Cancel(_ int, rlm realm) {
	u.assertOwner(0, rlm)
	if u.approved == "" {
		return
	}
	u.emit("UpgradeCancelled", "pkgPath", u.approved)
	u.approved, u.eta, u.prepared = "", 0, false
}

// Freeze ends upgrades for good, dropping any pending approval. The current
// implementation keeps serving and nothing can replace it, so users can
// trust its code rather than its owner. There is no way back. Owner only.
//
// There is no Unfreeze on purpose: a freeze that can be undone gives users
// nothing they can rely on. Freeze is also the only way to give up the power
// to upgrade. Renouncing the owner instead would also disable the admin
// methods that implementations gate on Owner, such as collecting fees.
func (u *upgrader) Freeze(_ int, rlm realm) {
	u.assertOwner(0, rlm)
	// Freezing before any implementation is live would leave the realm
	// unable to answer any call, forever.
	if u.pkgPath == "" {
		panic("upgrade: nothing to freeze before the first implementation")
	}
	// Clearing the approval is what stops a pending upgrade from landing
	// after the freeze. accept needs no frozen check of its own, because it
	// refuses when nothing is approved and approve refuses once frozen.
	u.approved, u.eta, u.prepared, u.frozen = "", 0, false, true
	u.emit("UpgradeFrozen", "pkgPath", u.pkgPath)
}

// TransferOwnership nominates next to accept the owner role. It still works
// after Freeze, because implementations may gate their own admin methods on
// Owner. Owner only.
//
// The current owner keeps control until next calls AcceptOwnership, preventing
// a valid but mistyped address from making the role unreachable.
func (u *upgrader) TransferOwnership(_ int, rlm realm, next address) {
	u.assertOwner(0, rlm)
	if !next.IsValid() {
		panic("upgrade: invalid owner")
	}
	u.pendingOwner = next
	u.emit("OwnershipTransferStarted", "from", u.owner.String(), "to", next.String())
}

// AcceptOwnership completes a pending transfer. The caller must be the
// nominated address acting as a user or realm.
func (u *upgrader) AcceptOwnership(_ int, rlm realm) {
	u.assertHolder(0, rlm)
	if !u.pendingOwner.IsValid() || rlm.Previous().Address() != u.pendingOwner {
		panic(ErrNotPendingOwner)
	}
	from := u.owner
	u.owner, u.pendingOwner = u.pendingOwner, ""
	u.emit("OwnershipTransferred", "from", from.String(), "to", u.owner.String())
}

// assertOwner panics unless rlm is the holding realm's live cur and its
// caller is the owner. IsCurrent comes first because a realm value whose
// frame has returned still reports that frame's Previous, so a value handed
// out during the owner's call could otherwise pass for the owner later.
func (u *upgrader) assertOwner(_ int, rlm realm) {
	u.assertHolder(0, rlm)
	if rlm.Previous().Address() != u.owner {
		panic(ErrUnauthorized)
	}
}

// prepare starts the delay of the pending approval. rlm is the holding
// realm's live cur, and its caller must be the approved realm, which proves
// its code is deployed. It runs once per approval, so a later call cannot
// push the ETA back.
func (u *upgrader) prepare(_ int, rlm realm, attrs ...string) {
	u.assertPreparable(0, rlm)
	u.eta, u.prepared = addDelay(runtime.ChainHeight(), u.delay), true
	u.emit("UpgradePrepared", append([]string{"pkgPath", u.approved, "eta", strconv.FormatInt(u.eta, 10)}, attrs...)...)
}

func addDelay(height, delay int64) int64 {
	const maxInt64 = 1<<63 - 1
	if delay > maxInt64-height {
		panic(ErrDelayOverflow)
	}
	return height + delay
}

// assertPreparable runs prepare's checks without preparing.
func (u *upgrader) assertPreparable(_ int, rlm realm) {
	u.assertApproved(0, rlm)
	if u.prepared {
		panic(ErrPrepared)
	}
}

// accept makes the calling realm the current implementation. rlm is the
// holding realm's live cur, and its caller must be the approved realm,
// once the delay has passed.
func (u *upgrader) accept(_ int, rlm realm, rollback bool) {
	caller := u.assertAcceptable(0, rlm)
	u.emit("Upgraded", "from", u.pkgPath, "to", caller, "rollback", strconv.FormatBool(rollback))
	u.pkgPath, u.approved, u.eta, u.prepared = caller, "", 0, false
}

// assertAcceptable runs accept's checks without accepting, so Proxy can
// check the next implementation's methods before anything changes. Doing
// that after accept would leave the upgrader naming an implementation the
// Proxy refused, wherever the panic is recovered.
func (u *upgrader) assertAcceptable(_ int, rlm realm) string {
	caller := u.assertApproved(0, rlm)
	if !u.prepared {
		panic(ErrNotPrepared)
	}
	if runtime.ChainHeight() < u.eta {
		panic(ErrTooEarly)
	}
	return caller
}

// assertApproved panics unless rlm is the holding realm's live cur and its
// caller is the approved realm, and returns the caller's path.
func (u *upgrader) assertApproved(_ int, rlm realm) string {
	u.assertHolder(0, rlm)
	caller := rlm.Previous().PkgPath()
	// A user caller has empty package path,
	// so an empty approval must not match.
	if u.approved == "" || caller != u.approved {
		panic(ErrNotApproved)
	}
	return caller
}

// assertHolder panics unless rlm is the holding realm's live cur.
func (u *upgrader) assertHolder(_ int, rlm realm) {
	if !rlm.IsCurrent() || rlm.PkgPath() != u.realm {
		panic(ErrSpoofedRealm)
	}
}

// emit emits an event with a "realm" attribute naming the holding realm.
// The event's pkg_path is this library's, shared by every holding realm.
func (u *upgrader) emit(typ string, attrs ...string) {
	chain.Emit(typ, append([]string{"realm", u.realm}, attrs...)...)
}

// PkgPath returns the realm that installed the current implementation,
// or empty string before the first one.
func (u *upgrader) PkgPath() string { return u.pkgPath }

// Approved returns the pending approval, or empty string
// if there is no pending approval.
func (u *upgrader) Approved() string { return u.approved }

// Owner returns the address that may approve, cancel, freeze and transfer
// ownership.
func (u *upgrader) Owner() address { return u.owner }

// PendingOwner returns the address nominated to accept ownership.
func (u *upgrader) PendingOwner() address { return u.pendingOwner }

// Frozen reports whether Freeze has ended upgrades.
func (u *upgrader) Frozen() bool { return u.frozen }

// ETA returns the first block height at which the pending approval can be
// accepted, or 0 if there is none or its delay has not started.
func (u *upgrader) ETA() int64 { return u.eta }

// onlyChars reports whether s holds only lowercase letters, digits and extra.
func onlyChars(s, extra string) bool {
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.ContainsRune(extra, c)) {
			return false
		}
	}
	return true
}
