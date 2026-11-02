# Design notes

These notes record the views, experiments and open issues behind the pattern.
The decisions themselves live in `docs/adr/`. API names follow ADR 0002, with
its single `Upgrade` entry point.

## 1. Lenses

### Realms as actors

A realm has the static shape of an actor but deliberately drops its dynamic
semantics.

| Aspect | Match with actors |
|---|---|
| Own address and assets (derived from the package path) | Strong |
| Encapsulation enforced at run time (readonly taint, `DidUpdate`) | Strong, with borrow rules #2 and #3 as exceptions |
| Unforgeable sender (`cur.Previous()`) | Strong |
| Message passing | Weak. Calls are synchronous and can reenter |
| Concurrency | Weak. The whole chain executes serially |
| Dynamic creation | Weak. `cur.Sub` mints an identity only |
| Failure handling | Opposite. A transaction is atomic as a whole, with no local isolation |

The lesson for upgrades comes from Erlang's hot code swap: keep the registered
name and the state in the process (the proxy) and swap only the code (the
implementation). Gno does better on one point, because a migration completes
atomically inside one transaction.

### Object capabilities

Gno is a hybrid: callers designate targets through ACLs, and prove identity
and authority with capabilities.

- In line with ocap: unforgeable references, encapsulation, identity as a
  capability (`cur`), sending as a capability (`NewBanker` requires
  `IsCurrent()`), confinement and immutability of `/p/` packages, and the
  facet convention (grc20's `Token` and `PrivateLedger`).
- Departing from ocap: anyone can import a realm by its package path and call
  it, which is ambient authority. Authorization compares `cur.Previous()`
  against an identity, which is an ACL.

In practice: ACLs at realm boundaries, capabilities inside a realm and between
it and `/p/` code. Two traps follow. Calling an arbitrary callback or interface
value without crossing leaks the caller's identity. Handing out a pointer to a
`/p/` object that has mutating methods leaks write access through borrow rule
#2.

### The store as a DBMS

The proxy is the database server and implementations are replaceable stored
procedures.

| DBMS | This pattern |
|---|---|
| Tables and key encoding | `Store` tables and row keys |
| Schema migration | `Migrate`, added tables, lazy migration |
| ACID and isolation | Transaction atomicity, serial execution of the whole chain |
| Storage engine and write amplification | bptree, which rewrites the node path on every write |
| Query cost model | Gas |
| `GRANT` | `View`, `Tx` and `Custody`, per call |

The analogy breaks in three places. A database has no PkgID ownership, where
an object an implementation allocates belongs to that implementation. Index
integrity is up to implementation code. Reentrancy replaces concurrency as the
hazard.

## 2. How the design evolved

1. **Pass the proxy's `cur` and store to the implementation.** Called without
   crossing, the implementation keeps the proxy's realm context, so
   `rlm.Previous()` is the user, while its storage context moves to the
   implementation (borrow rule #1). It worked, but the experiments in section 3
   showed authority leaking.
2. **Switch to capability handles.** The implementation gets `Tx` and `Custody`,
   which hold the proxy's `cur` privately, instead of `cur` itself. A realm
   value cannot be persisted, so an implementation that stores a handle aborts
   the transaction, and revocation needs no bookkeeping.
3. **Keep the store in one tree.** A bptree per table costs about 5KB per table
   up front. Prefixing keys with the table name and keeping one tree cut the
   vault demo from 16.9KB to 5.5KB and the AMM demo from 23.7KB to 6.7KB.
4. **Face the frozen interface.** Adding an operation meant touching the proxy
   function, the interface and the implementation, and the first two cannot
   change after deployment. Alternatives considered:

   | Option | Trade off |
   |---|---|
   | One typed interface method per operation | Type safe, but the set of operations is fixed at deployment |
   | A string entry point or a handler registry | Extensible, but every caller encodes and parses strings |
   | Command types (`/p/` structs and `Handle(cmd)`) | The proxy can stay fixed and realm callers keep static types, but results are `any` and support is checked at run time |
   | Generating proxy wrappers off chain | Saves typing, but the interface is still frozen |

   This repository uses string `Call` with a grow-only `Methods` API by
   default, and `Invoke` and `Inspect` only for entry points that must be
   typed.
5. **Simplify the lifecycle (ADR 0002).** `Bootstrap`, `Prepare`, `Register`
   and `Activate` became one `Upgrade(next)`. An implementation is identified
   by the realm path that installed it and its value, compared with `==`.

## 3. What experiments showed

Each result comes from throwaway realms on gno master and was reproduced after
updating to a newer upstream.

| Experiment | Result | Consequence |
|---|---|---|
| The implementation calls `cross(rlm)` with the `rlm` it was given | Works, and the target sees the proxy as its caller | Given `cur`, an implementation can call anything as the proxy |
| Store a struct value | Billed to and owned by the proxy | Values are safe to store |
| Store a struct pointer the implementation allocated | Billed to the implementation, which can still mutate it after being replaced | Values are limited to plain types |
| Call a callback without crossing | It runs in the proxy's realm context | Never call untrusted code without crossing |
| Keep the tree pointer handed over and write later | The write succeeds | Raw tables are never handed out |
| A realm value inside a temporary struct, then store the struct | Usable, and storing fails with `cannot persist realm value` | The basis for `Tx` and `Custody` |
| Keep a `RealmTeller` and use it later | It moves the proxy's tokens | `Custody` never returns a teller |
| Keep a `RealmSend` banker and use it later | It sends the proxy's coins, as the stdlib intends | `Custody` never returns a banker |
| Declare a zero value of another realm's `/r/` type | Allowed, while a composite literal is refused | Handle methods start with a nil check and `IsCurrent()` |
| Pass a `/p/` command struct as an interface value in a crossing call | Works | Command types are viable |

Side findings:

- A function whose first parameter is a `realm` is crossing
  (`FuncType.IsCrossing`). That is why `/p/` code takes `_ int, rlm realm`.
- MsgCall accepts only primitive arguments: `[]byte`, but not `[]string`.
- `revive` does not roll back state yet. A filetest sees writes made before a
  failure, where a real transaction would revert them.
- A package under `…/vN` must be named after the element before `/vN`, so an
  implementation imports its proxy under an alias.

## 4. Decisions and reasons

- **Persistent authority stays in the proxy.** A public realm cannot be
  deleted, so the question is what a replaced implementation can still do.
- **Authority moves only as per call capabilities.** With an allowlist,
  revocation depends on keeping the list right. With capabilities, the VM
  refuses to persist them, so revocation is automatic.
- **Each handle grants only what it names.** `View` reads, `Tx` writes tables,
  and `Custody` moves assets without returning the banker or teller it builds.
  Token approvals go through `ApproveForCall` only and are revoked before a
  successful call returns. A panic aborts the transaction.
- **Schemas change by addition.** Changing a row format in place leaves a
  rolled back implementation unable to read state.
- **Approval is where code gets audited.** An approved implementation is fully
  trusted while it runs. The delay gives users time to review and exit. It is
  not a sandbox.

## 5. Open issues

### Design

- **Outward calls**: an implementation acts outside the proxy only through what
  the proxy hands it. A new kind of outward call, such as an oracle or another
  protocol, means a new proxy, so `Custody` must cover every asset movement the
  app will need before deployment.
- **Typed proxy interfaces**: the interface used with `Invoke` (the AMM's
  `Pool`) cannot change. Keep it to what must be typed.
- **Callbacks and reentrancy**: an implementation that holds only handles cannot
  cross into anything, so it cannot reenter. A typed proxy that builds callbacks
  itself (the AMM's `pay`) must lock every entry point. Flash swaps need a
  separate design.
- **Receiving payments**: for native coins, `unsafe.OriginSend()` with
  `IsUserCall()` is the only direct route. The alternatives are balance diffs,
  which let other realms deposit but hand stray coins to the next depositor,
  and GRC20 allowances.
- **Large migrations**: a migration cannot exceed one transaction's gas. Use
  compatible schema extensions or lazy migration.

### Implementation

- **Admin address**: `Admin0` in the example realms is gno's default test1
  account, whose mnemonic is public. Replace it before any real deployment.
- **Zero value `Tx`**: it lacks a nil check, so it fails with a nil interface
  panic. It is refused either way, but the message is unhelpful. Decide whether
  to check explicitly as `Custody` does.
- **Cost**: a fanout 32 bptree is efficient per entry but has a fixed root cost,
  and every row write rewrites its node path.
