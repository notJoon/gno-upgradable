# Keep Persistent Authority in the Proxy

> **Deprecated.** Superseded by [ADR 0002](0002-identify-implementations-by-value.md), which keeps this decision and replaces the `Bootstrap`, `Prepare` and `Register` lifecycle it describes.

The upgrade pattern follows the object capability model. The proxy retains persistent state, assets, and upgrade authority. Implementations receive `Tx` and `Custody` capabilities that are valid only during the current call. Activation uses the exact implementation value saved by `Prepare`. Bootstrap and ownership changes require explicit owner actions so authority cannot move implicitly. We do not expose a raw realm, banker, or teller. Temporary token approvals are tracked and cleared before a successful call returns, while a panic aborts the transaction. Future capabilities must grant only the authority they need and expire with the call.
