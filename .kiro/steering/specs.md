---
inclusion: always
---

# How specs are written in this repository

## Scope and vocabulary
- Product context is in `product.md`, stack in `tech.md`, test environment in `testing.md`. Do not restate them in specs.
- Always out of scope unless a requirement says otherwise: bootloader, initramfs and disk-encryption changes; ISO building; releases other than 24.04 LTS and 26.04 LTS; architectures other than amd64.
- Define any new term in the spec's Glossary before using it in a criterion.

## requirements.md
- EARS only, one SHALL per criterion, one observable response.
- Numbers, not adjectives. Never "fast", "large", "appropriate", "user-friendly", "secure", "handle".
- Every happy-path criterion has an IF twin for failure, interruption, missing network or missing permission.
- Write invariants as universal statements so they can become property tests.
- Never renumber existing requirements; append new ones.

## design.md
- Follow `DESIGN.md` at the repo root. A departure from it needs a stated reason.
- Interfaces concrete enough to implement from: command-line syntax, exit codes, file formats, package names, paths.
- Error handling listed per IF criterion.
- A new dependency needs a one-line justification and must be added to `tech.md`.
- Testing strategy uses `bats-core`, `shellcheck` and the VM harness in `test/vm/`.
- Diagrams in Mermaid.

## tasks.md
- Every task ends with `_Requirements: <ids>_`.
- Task size 15–90 minutes, one coherent set of files per task; tasks in the same phase must not touch the same files.
- Tests live in the same task as the code they cover, or the next one.
- Order: VM test harness → feasibility spikes → packaging foundations → core → integration → polish.
- Every task that installs, removes or builds anything states that it runs in a test VM, and names the release.
- Add a `Checkpoint` task after every 3–5 tasks: run `test/run-all`, then stop for questions.
- No task may run `git push`, publish to the apt repo, or run `sudo`, `apt` or `motanka` commands on the development host.

## Definition of done
- All required tasks checked, lint and `test/run-all` green on 26.04, release-specific tests green on 24.04.
- Every acceptance criterion verified by a test or a documented manual check in a VM.
- Spec files updated to match what was built, then committed with the code.
