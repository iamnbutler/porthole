# AGENTS

<!-- lane:protocol -->
## Context memory

- Before editing a file, read `.lane/memory/<path>/` if it exists, or run `lane why <path>`.
- Record non-obvious findings with `lane note add <path> -a <anchor> "..."`.
- Do not edit `.lane/` by hand; landing manages it.
- Land with `lane merge`, or `lane push` where trunk is protected, then `lane prune` once it merges.
- Detailed workflow lives in `.agents/skills/lane/SKILL.md`; run `lane install skill` if it is absent.
<!-- /lane:protocol -->

## Lane lifecycle

Every change happens in a lane worktree, never in the main checkout:

1. `lane new <name>`, then work in the tree it prints.
2. `lane why <path>` before editing a file.
3. Commit. Add `Why: <path> | <note>` trailers only for constraints the code doesn't show.
4. `lane check`, then confirm, replace or retire stale notes.
5. `lane push`, open a PR, squash-merge it.
6. `git pull --ff-only` in the main checkout, then `lane prune --dry-run`, and `lane rm <name>` for merged lanes prune misses.
