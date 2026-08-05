# Multi-root workspaces

Date: 2026-08-05. Status: implemented.

Projects became VS Code-style multi-root workspaces. One workspace = several folders; one session store per workspace; the agent reads/writes/executes across all roots.

## Model

- `Workspace` (core, `Workspaces/`): `id`, `name`, `folders: [URL]` (first = primary), `created`. Persisted in `~/.config/ninty/workspaces.json` via `WorkspaceStore`.
- Primary root: bash cwd, config source, default for relative paths.
- Migration: legacy `recentProjects` UserDefaults entries auto-wrap into single-folder workspaces with `id = SessionStore.projectHash(folder)` — existing session directories are reused unchanged.

## Path rules (`ToolContext`)

- Absolute → pass through.
- `folderName/relative` → the root whose last path component matches (multi-root only).
- Bare root folder name (`meetily`) → that root itself.
- Plain relative → primary root. Read-side tools (read/list/glob/grep) use `resolveExisting`: primary hit wins, otherwise the first root where the path exists; misses resolve to the primary path. Writes/edits stay strict (primary or explicit prefix).
- Sandbox: inside ANY root. `mentionPath(for:)` produces the display/mention form (prefixed only when multi-root).

## Live updates

- Editing a workspace's folders propagates to open chats: `AgentSession.setProjectRoots` rebuilds the system prompt's per-root listing.

## Queued steer messages

- Sending while streaming appends the user bubble immediately, flagged `isQueued` (dimmed, "queued" caption). `queueChanged` re-syncs flags (last N user bubbles); draining flips the flag so the reply lands in a new assistant bubble. `SessionEvent.followupStarted` resets per-turn timing only. Pulling a queued message back to the composer removes its bubble.

## Session storage

- `SessionStore(storageKey:)` — key = workspace id. `init(projectRoot:)` / `init(workspace:)` are thin wrappers; a legacy-hash workspace id makes them share a directory.

## Config

- `ConfigLoader.load(roots:)`: merged config from the primary root (walk-up); `AGENTS.md` concatenated from every root that has one, in root order.

## UI

- Sidebar: workspace rows (name + `N folders` badge), context menu Add Folder… / Remove Folder ▸ / Delete Workspace (removing the last folder deletes the workspace, with the same session-wipe confirmation).
- Tabs: avatar = workspace initial; mixed-workspace strip compares workspace ids.
- @-mentions: cached per workspace from all roots (folder-prefixed when multi-root); drops/paste relativize via `ToolContext.mentionPath`.
- Side panel: one git section per repo folder; non-repo roots skipped.

## Known edges

- Two roots with the same folder name: prefix resolution takes the first match.
- Permission path globs: plain relative patterns match the primary root; use folder prefixes for non-primary roots.
