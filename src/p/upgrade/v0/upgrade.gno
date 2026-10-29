package upgrade

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
)

const (
	ErrInvalidPath  = "upgrade: approved path must be a realm path without a subpath"
	ErrSpoofedRealm = "upgrade: realm must be the proxy's live current realm"
	ErrNotApproved  = "upgrade: caller is not the approved implementation"
	ErrTooEarly     = "upgrade: approval is still in its delay"
)

// Upgrader records a proxy realm's current implementation and the one
// approved to replace it.
//
// Once an implementation is live, an approval can be accepted only after
// delay blocks, so users can see it coming and leave first. The first
// implementation has no delay because there is nothing to protect yet.
type Upgrader struct {
	delay    int64
	pkgPath  string
	approved string
	eta      int64 // first height at which approved may be accepted
}

// New returns an Upgrader whose approvals wait delay blocks.
func New(delay int64) *Upgrader {
	if delay < 0 {
		panic("upgrade: negative delay")
	}
	return &Upgrader{delay: delay}
}

// Approve lets the realm at pkgPath become the next implementation,
// replacing any pending approval.
func (u *Upgrader) Approve(pkgPath string) {
	// pkgPath must look like `<domain>/r/<path>` and must not name a subrealm.
	// Splitting into at most three parts keeps the rest of the whole path together.
	//
	// 	Example: "example.com/r/myrealm"
	//  After splitting: ["example.com", "r", "myrealm"]
	//
	// This check only catches typos in the approval. The real gate is in Accept,
	// which compares the approval with the calling realm's pkgpath,
	// and no deployed realm can match a malformed path.
	parts := strings.SplitN(pkgPath, "/", 3)
	_, _, isSub := chain.SplitPkgSubPath(pkgPath)
	if len(parts) != 3 || parts[0] == "" || parts[1] != "r" || parts[2] == "" || isSub {
		panic(ErrInvalidPath)
	}
	u.approved = pkgPath
	u.eta = runtime.ChainHeight()
	if u.pkgPath != "" {
		u.eta += u.delay
	}
	chain.Emit("UpgradeApproved", "pkgPath", pkgPath, "eta", strconv.FormatInt(u.eta, 10))
}

// Cancel drops the pending approval, if any.
func (u *Upgrader) Cancel() {
	if u.approved == "" {
		return
	}
	chain.Emit("UpgradeCancelled", "pkgPath", u.approved)
	u.approved, u.eta = "", 0
}

func (u *Upgrader) Accept(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}

	caller := rlm.Previous().PkgPath()
	// A user caller has empty package path,
	// so an empty approval must not match.
	if u.approved == "" || caller != u.approved {
		panic(ErrNotApproved)
	}
	if runtime.ChainHeight() < u.eta {
		panic(ErrTooEarly)
	}
	chain.Emit("Upgraded", "from", u.pkgPath, "to", caller)
	u.pkgPath, u.approved, u.eta = caller, "", 0
}

// PkgPath returns the package path of the current implementation,
// or empty string before the first implementation is accepted.
//
// It names the realm that registered, which is not necessarily the realm
// that declares the registered value's type. Audit both.
func (u *Upgrader) PkgPath() string { return u.pkgPath }

// Approved returns the pending approval, or empty string
// if there is no pending approval.
func (u *Upgrader) Approved() string { return u.approved }

// ETA returns the first block height at which the pending approval can be
// accepted, or 0 if there is none.
func (u *Upgrader) ETA() int64 { return u.eta }
