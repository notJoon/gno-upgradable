# gno-upgradable

An upgradable realm pattern for Gno. The proxy realm keeps the permanent
address, state, coins, and GRC20 tokens. An implementation realm supplies the
behavior and can be replaced after an on-chain delay.

The repository contains the reusable `gno.land/p/upgrade/v0` package and two
examples:

- `vault` demonstrates string-dispatched calls, migrations, fees, and rollback.
- `amm` demonstrates typed entry points, token custody, callbacks, and
  reentrancy protection.

The examples exist to test the pattern. The AMM is not production-ready: its
liquidity and arithmetic rules are deliberately simplified.

## Upgrade lifecycle

1. The proxy creates an empty `upgrade.Proxy` with an owner and delay.
2. After the first implementation realm is deployed, the owner approves its
   path and it calls `Bootstrap` with its fixed implementation value. It has no
   delay because there is no live code to protect yet.
3. The owner deploys and approves the next implementation realm.
4. The approved realm calls `Prepare`. This checks the grow-only method API and
   starts the full delay only after the code exists on-chain.
5. At or after `ETA`, the same realm calls parameterless `Register`. The proxy
   activates the exact implementation saved by `Prepare` and calls `Migrate`
   in the same transaction.

The package authenticates the approved realm when it calls `Bootstrap`, but it
cannot query whether an arbitrary package path is already deployed. The owner
must therefore treat “deploy, inspect, then approve” as an operational
invariant for the first implementation.

The owner may cancel a pending upgrade. `Freeze` permanently disables future
upgrades without disabling implementation-level admin methods. A rollback is
the same delayed lifecycle applied to a previously served implementation.
Ownership transfer completes only after the nominated address calls
`AcceptOwnership` through the proxy's corresponding forwarding function.

## Why object capabilities

A public realm cannot be deleted, so a replaced implementation stays callable
forever. The design question is therefore not only who may call the proxy, but
what an implementation can still do after it has been replaced.

In Gno, a live `cur` is authority, and some things built from it outlive the
call: a `RealmSend` banker, a GRC20 `RealmTeller` bound to the proxy's address,
and a pointer into the proxy's state. An implementation given the proxy's `cur`
or its raw tables could keep any of these and use them after an upgrade. An
allowlist of retired implementations would make revocation depend on keeping
that list correct.

The pattern instead hands authority to implementations as objects scoped to one
call:

- `Tx` and `Custody` hold the proxy's `cur` privately. Gno refuses to persist a
  realm value, so storing either handle aborts the transaction, and their
  methods reject use after the call. Revocation needs no bookkeeping: an
  implementation the proxy no longer calls has nothing left to use.
- Each handle grants only what it names. `View` reads, `Tx` writes the proxy's
  tables, and `Custody` moves assets without returning the banker or teller it
  builds.
- Handles cannot be forged. Opening one over the proxy requires the proxy's
  live `cur`, and a zero value declared elsewhere has no realm and refuses
  every call.

This limits what a replaced implementation can do. It does not limit an
approved implementation while it runs, as the next section explains.

## Security model

The proxy owns all persistent authority. Implementations receive a `Tx` and a
`Custody` only while the proxy's crossing call is live. Gno refuses to persist
these handles, and their methods reject use outside that frame. State values are
restricted to plain types so an old implementation cannot retain a writable
pointer into proxy state.

An approved implementation is still fully trusted while it runs. It can change
state and move every asset held by the proxy. The delay gives users time to
audit and exit; it does not sandbox bad code. In particular:

- Keep implementation values stateless. Store application state through `Tx`
  and hold assets through `Custody`.
- `Custody` deliberately exposes token transfers but not approvals. A caller
  can recover an implementation panic without running pure-package defers, so
  this package cannot guarantee that an allowance is temporary.
- Export parameterless `Prepare` and `Activate` functions. `Prepare` must pass a
  fixed implementation value; `Activate` registers that saved value.
- `Methods` checks names and call/query placement only. Review argument,
  result, authorization, and semantic compatibility separately.
- Add tables when changing schemas. An in-place row-format change can make an
  old implementation unable to read state after rollback.
- A typed proxy that makes callbacks must lock every entry point that can read
  inconsistent state or replace the implementation. The AMM applies the same
  lock to `Swap`, reads, string calls, and `Register`.
- Keep retired method names and return a clear panic. Only a rollback may
  temporarily leave a previously served method unavailable.

Every upgrade event includes the proxy realm in a `realm` attribute. `Render`
also prepends a pending-upgrade, rollback, or freeze banner that implementations
cannot hide. Production monitoring should consume the events rather than rely
on users opening the rendered page.

## Development

`mise.toml` pins the Gno release currently running on `gnoland-1`. Confirm the
live version from `https://rpc.gno.land/status` or the official mainnet upgrade
ledger before changing `GNO_REF`; keep `integration/go.mod` on the same tag.

```sh
mise run setup
mise run lint
mise run test
mise run integration
mise run integration-gnodev
```

`test` runs package tests and filetests. `integration` starts an in-memory
gno.land node and verifies signed upgrade transactions, state continuity, and
AMM callback reentrancy with the pinned mainnet release. CI additionally runs
`integration-gnodev`, which deploys v2 with `addpkg` against an isolated gnodev
chain and checks that state survives activation.

Before deploying a proxy:

- choose an explicit admin user or governance realm and an escape delay;
- make every admin forwarder call the checks on `Proxy` rather than duplicating
  authorization in the realm;
- test activation, cancellation, ownership transfer, freeze, migration,
  rollback, unexpected coins, and retained-handle rejection;
- test callback and asset flows on a real node, not only with filetests; and
- audit both the approved realm and the concrete implementation type it passes
  to `Prepare`.
