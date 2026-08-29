---
title: Enable delegation worktree isolation and raise concurrency
status: done
blocked_by: []
depends_on: []
---

# #03 — Enable delegation worktree isolation and raise concurrency

The main agent will orchestrate parallel coding teams via `delegate_task`. Enable isolated git
worktrees per child and raise the concurrency ceiling so explore + implement + review can run together.

## Changes

- `roles/hermes/templates/config.yaml.j2:56-59` — update the `delegation:` block:
  ```
  delegation:
    max_concurrent_children: 5
    worktree_isolation: true
    provider: nous
    model: qwen/qwen3-coder-flash
  ```
  (`provider`/`model` unchanged; `worktree_isolation` added; `max_concurrent_children` 3 → 5.)

## Acceptance

- [ ] Rendered `config.yaml` contains `worktree_isolation: true` and `max_concurrent_children: 5`.
- [ ] `ansible-playbook --syntax-check` passes.
