---
name: review-upgrade-usability
description: Review gno.land/p/upgrade/v0 changes for contract-developer usability, interface depth, and portability after automated criteria pass. Use for manual design evaluation, not CI validation.
---

# Review Upgrade Usability

Evaluate the package through its public interface as a contract developer. Do
not add this review to CI or repeat lint, package tests, filetests, or integration
checks owned by `mise run criteria`.

Read the changed interface, README quick starts, and the smallest relevant
vault, AMM, or typed-only consumer. Compare the current branch with its PR base.

For each affected developer journey, score these from 0 to 2 and cite concrete
consumer code:

- **Completion:** unsupported; workaround required; public interface is enough.
- **Misuse resistance:** raw/runtime failure; package error; compile or preflight rejection.
- **Locality:** three or more consumer edit sites; two sites; one seam.
- **Caller burden:** hidden rules or globals; repeated adapter code; one type or call.
- **Portability:** one example only; some proxy modes; typed, dispatcher, and relevant path variants.

Check manually:

1. Did the change add a rule that every proxy or implementation must remember?
2. Did responsibility move into the package, or merely move between consumers?
3. Are names, lifecycle order, panic modes, and typed/string trade-offs clear from the interface and quick start?
4. If the package were removed, would the complexity reappear in every consumer?
5. Are stated non-goals explicit, so a structural limit is not mistaken for a supported workflow?

Report the before/after score, new rules added or removed, and any safety concern
that automated criteria cannot establish. Do not turn subjective scores into a
merge gate; they are review evidence for the maintainer.
