---
description: 'Ansible conventions and best practices'
applyTo: '**/*.yaml, **/*.yml'
---

# Ansible Conventions and Best Practices

## General Instructions

- Use Ansible to configure and manage infrastructure.
- Use version control for your Ansible configurations.
- Keep things simple; only use advanced features when necessary
- Give every play, block, and task a concise but descriptive `name`
  - Start names with an action verb that indicates the operation being performed, such as "Install," "Configure," or "Copy"
  - Capitalize the first letter of the task name
  - Omit periods from the end of task names for brevity
  - Omit the role name from role tasks; Ansible will automatically display the role name when running a role
  - When including tasks from a separate file, you may include the filename in each task name to make tasks easier to locate (e.g., `<TASK_FILENAME> : <TASK_NAME>`)
- Use comments to provide additional context about **what**, **how**, and/or **why** something is being done
  - Don't include redundant comments
- Use dynamic inventory for cloud resources
  - Use tags to dynamically create groups based on environment, function, location, etc.
  - Use `group_vars` to set variables based on these attributes
- Use idempotent Ansible modules whenever possible; avoid `shell`, `command`, and `raw`, as they break idempotency
  - If you have to use `shell` or `command`, use the `creates:` or `removes:` parameter, where feasible, to prevent unnecessary execution
- Use [fully qualified collection names (FQCN)](https://docs.ansible.com/ansible/latest/reference_appendices/glossary.html#term-Fully-Qualified-Collection-Name-FQCN) to ensure the correct module or plugin is selected
  - Use the `ansible.builtin` collection for [builtin modules and plugins](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/index.html#plugin-index)
- Group related tasks together to improve readability and modularity
- For modules where `state` is optional, explicitly set `state: present` or `state: absent` to improve clarity and consistency
- Use the lowest privileges necessary to perform a task
  - Only set `become: true` at the play level or on an `include:` statement, if all included tasks require super user privileges; otherwise, specify `become: true` at the task level
  - Only set `become: true` on a task if it requires super user privileges

## Secret Management

This repository does **not** use Ansible Vault or a third-party secrets manager — it uses a SOPS +
age encrypted store, committed to the repository (see `docs/adr/0007-sops-age-encrypted-secrets.md` for
why, and `README.md`'s "Local Secrets Workflow" for the day-to-day commands).

- Every credential the `secrets` resolver role needs is one entry in the manifest,
  `group_vars/all/secrets.yml`'s `secrets_manifest` (`env:`, `required:`, optional `default:`). The
  resolver reads it from the environment at `lookup('env', ...)` time — **do not** add a new
  `lookup('env', ...)` call anywhere else in the codebase; the resolver is the single seam, and a lint
  check enforces this.
- The actual value lives only in the encrypted store, `secrets/secrets.enc.env`, maintained with
  `scripts/secrets` (`fill`, `edit`, `check`, `rotate`, `add-recipient`, `remove-recipient`,
  `init-key`) — never hand-edited, never decrypted to a file.
- Playbooks are run only through `scripts/deploy`, which decrypts the store into the child Ansible
  process's environment (never to disk) and redacts every decrypted value from its own output as it
  streams. Do not invoke `ansible-playbook` directly against `site.yml` with real secrets in scope, and
  do not add a task that writes a secret-bearing file, log, or registered result without `no_log: true`
  (`scripts/check_secret_suppression.py`, run by `tests/lint.sh`, checks for this statically).
- A value that isn't a manifest credential at all (rare — currently just `TARGET_HOST` and
  `AUDIT_EXTRA_TERMS`) is a *declared extra*, listed in exactly one place:
  `scripts/generate-env.py`'s `EXTRA` list.

## Style

- Use 2-space indentation and always indent lists
- Separate each of the following with a single blank line:
  - Two host blocks
  - Two task blocks
  - Host and include blocks
- Use `snake_case` for variable names
- Sort variables alphabetically when defining them in `vars:` maps or variable files
- Always use multi-line map syntax, regardless of how many pairs exist in the map
  - It improves readability and reduces changeset collisions for version control
- Prefer single quotes over double quotes
  - The only time you should use double quotes is when they are nested within single quotes (e.g. Jinja map reference), or when your string requires escaping characters (e.g., using "\n" to represent a newline)
  - If you must write a long string, use folded block scalar syntax (i.e., `>`) to replace newlines with spaces or literal block scalar syntax (i.e., `|`) to preserve newlines; omit all special quoting
- The `host` section of a play should follow this general order:
  - `hosts` declaration
  - Host options in alphabetical order (e.g., `become`, `remote_user`, `vars`)
  - `pre_tasks`
  - `roles`
  - `tasks`
- Each task should follow this general order:
  - `name`
  - Task declaration (e.g., `service:`, `package:`)
  - Task parameters (using multi-line map syntax)
  - Loop operators (e.g., `loop`)
  - Task options in alphabetical order (e.g. `become`, `ignore_errors`, `register`)
  - `tags`
- For `include` statements, quote filenames and only use blank lines between `include` statements if they are multi-line (e.g., they have tags)

## Linting

- Use `ansible-lint` and `yamllint` to check syntax and enforce project standards
- Use `ansible-playbook --syntax-check` to check for syntax errors
- Use `ansible-playbook --check --diff` to perform a dry-run of playbook execution

<!-- 
These guidelines were based on, or copied from, the following sources:

- [Ansible Documentation - Tips and Tricks](https://docs.ansible.com/ansible/latest/tips_tricks/index.html)
- [Whitecloud Ansible Styleguide](https://github.com/whitecloud/ansible-styleguide)
-->
