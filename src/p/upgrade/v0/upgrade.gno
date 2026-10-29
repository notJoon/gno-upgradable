package upgrade

import (
	"chain"
	"strings"
)

const (
	ErrInvalidPath  = "upgrade: approved path must be a realm path without a subpath"
	ErrSpoofedRealm = "upgrade: realm must be the proxy's live current realm"
	ErrNotApproved  = "upgrade: caller is not the approved implementation"
)

// Upgrader records the current impl's package path and
// pending approval of a proxy realm.
type Upgrader struct {
	pkgPath  string
	approved string
}

func New() *Upgrader {
	return &Upgrader{}
}

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
	u.pkgPath, u.approved = caller, ""
}

// PkgPath returns the package path of the current implementation,
// or empty string before the first implementation is accepted.
func (u *Upgrader) PkgPath() string { return u.pkgPath }

// Approved returns the pending approval, or empty string
// if there is no pending approval.
func (u *Upgrader) Approved() string { return u.approved }
