# Identify Implementations by Value

Supersedes [ADR 0001](0001-keep-authority-in-the-proxy.md).

The proxy keeps persistent state, assets, and upgrade authority, as ADR 0001 decided. Implementations receive `Tx` and `Custody` capabilities that are valid only during the current call. We do not expose a raw realm, banker, or teller. Temporary token approvals are tracked and cleared before a successful call returns, while a panic aborts the transaction. Future capabilities must grant only the authority they need and expire with the call. Ownership changes still require explicit owner actions.

## Identity

The proxy names an implementation by the realm path that installed it and the value itself, compared with `==`. The comparison checks the dynamic type, including the package that declares it, and the value. This pair replaces the self-reported implementation ID and the SHA-256 manifest hash, which an implementation chose for itself and which could not authenticate anything.

Both halves come from the chain in Gno v1.5.1:

- The path is the caller of `Upgrade`, which the chain authenticates.
- The value's type decides the code that runs. A public package path can be deployed once, so that code never changes. A private realm can be redeployed by its creator, but a value whose type a private realm declares cannot be stored in another realm, so the proxy only ever holds values of public types.

The value alone is not enough. Another realm cannot write a composite literal of a realm-declared type, but it can declare a zero value of an exported one, which equals the value its own realm passes. Matching the path as well keeps that realm from claiming another realm's rollback.

A rollback is a pair that served before. Upgrade installs only the value it saved when the delay started. Method lists are copied when a value is checked, and calls route through that copy, so nothing needs to be fingerprinted.

Implementation values should be value types such as an empty struct. A value holding a slice, map, or func is refused with a clear error. A pointer compares by address, so a fresh pointer on each call never matches the saved one.

## Lifecycle

`Bootstrap`, `Prepare`, and `Register` are replaced by one `Upgrade(next)`, called by the approved realm. With nothing live it installs `next` at once. Otherwise the first call checks `next` against the API, saves it, and starts the delay. A call after the delay installs the saved value, which `next` must equal, and runs its `Migrate`. A later call cannot push the ETA back. Each proxy and implementation realm exports one lifecycle function instead of three.

The upgrade state machine is an internal type of the package. Nothing outside `Proxy` used it, and keeping a second public copy of the rollback history let the two disagree.

## Consequences

- `Impl` only requires `Migrate`.
- Events no longer carry an implementation label, because Gno has no reflection to name a dynamic type. Observers read the approved realm's code to see which value it passes to `Upgrade`, then the code of that value's type.
- A realm path that served before gets the rollback exception only for the same value, and a value gets it only from the realm that installed it.
