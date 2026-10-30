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
- `Custody.ApproveForCall` is temporary: the proxy clears every allowance it
  creates before the call commits. Persistent delegation needs a separate,
  explicitly tracked design.
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
