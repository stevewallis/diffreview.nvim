# diffreview.nvim

A small Git review workspace for Neovim 0.11+: diff splits, persistent reviewed
marks, quickfix navigation, and an optional Snacks picker.

I liked using `git difftool --dir-diff` for reviews, but was getting on large reviews
about what I'd done, so wanted a way to mark a file as reviewed (like on github prs).

## Install with Lazy

```lua
{
  "stevewallis/diffreview.nvim",
  dev = true, -- local checkout at ~/code/nvim/diffreview.nvim
  cmd = { "DiffReview", "DiffReviewPick" },
  opts = {},
}
```

The repository is local during development; this is not yet a published plugin.
No dependency on Neovim's bundled DiffTool or on Snacks for core functionality.

## Usage

* `:DiffReview master`: compare master with tracked working-tree changes,
  including staged changes. No argument defaults to HEAD.
* `:DiffReview master HEAD`: compare two revisions.
* `:DiffReviewDone`: toggle the current file's `[ ]` / `[x]` mark in place.
  Reviewed files stay visible by default. In pending-only mode, marking reviewed
  removes the entry and advances to the next pending file.
* `:DiffReviewDoneNext` / `:DiffReviewDonePrev`: mark the current file reviewed,
  then open the next / previous pending file, in either mode.

No keys are mapped by default. `opts.keys` maps review actions only while a
review is open, acting only in its tab; mappings they replace are restored when
the review tab closes:

```lua
opts = { keys = { done_next = "]r", done_prev = "[r" } }
```
* `:DiffReviewAll`: toggle all files / pending files.
* `:DiffReviewRefresh`: query Git again, including newly changed tracked files.
* `:DiffReviewPick`: searchable Snacks picker. Ctrl-D toggles a mark; Ctrl-A
  toggles all/pending. Enter opens the comparison.
* `:DiffReviewNotes`: toggle a Markdown Snacks scratch buffer for this review.
  It uses your scratch window settings and autowrite preference, and appears in
  `Snacks.scratch.select()`. Without Snacks, it opens a normal notes split.

Changing `'wrap'` in either review split applies it to both, and it stays set
when moving between files, so the scroll-bound sides stay aligned.

`require("diffreview").active()` returns true while the review tab is current,
for routing your own mappings (e.g. a general quickfix picker) to review actions.

Use regular quickfix commands (`:cnext`, `:cprevious`, `:cc`, `:copen`) to navigate.
Set `opts = { show_reviewed = false }` to start in pending-only mode instead.
Reviews open in a separate tab; close it before starting another review. Existing
quickfix lists stay in the quickfix history. Keep the two review splits open;
notes can occupy an additional split.

Working-tree text files remain normal editable buffers. Historical versions and
absent files are read-only scratch buffers with syntax highlighting, no filetype
events, and disabled diagnostics, so standard FileType-based LSP startup does not
run on them. Save edits before marking a file reviewed. Unsaved edits are not
included in Git comparisons or fingerprints.

Marks live in `stdpath('state')/diffreview`, outside the repository. With Snacks,
notes live in your configured scratch directory; otherwise they live beside the
marks. Existing split-based notes are copied into a new review scratch buffer on
first opening, without deleting the original or overwriting existing scratch notes.
Scratch identity follows the review, independent of your current directory,
buffer filetype, or keybinding count. Your ordinary scratch buffers are separate.
Review identity includes the worktree root, branch name, and revision expressions.
Each mark fingerprints both complete file contents, paths, and Git file modes.
Changing either side makes that comparison pending. Unchanged comparisons retain
their marks across new commits. Returning to precisely the reviewed contents also
restores the mark. Use the same revision spelling to resume the same review.

Refresh runs after saves and on focus gain, debounced by 200ms. It re-resolves the
supplied revisions, so moving a base branch also updates the comparison. Configure
`opts = { auto_refresh = false }` to refresh manually. An optional `state_dir`
overrides the mark/fallback-note storage directory. Snacks notes follow your
scratch autowrite setting (on by default); ordinary notes use `:write` to save.

## Current limits

This is an initial implementation. Historical blobs are read in one Git batch
and cached by object ID for the session. Startup scans once; marking checks only
the selected file's comparison. Syntax highlighting loads when a comparison is
opened. Git queries and hashing remain synchronous, so large repositories/files
may still pause the UI. Untracked files are excluded until
added to Git. Binary files display a placeholder, but their full contents are
fingerprinted. Symlinks show their link text. Working-tree submodule changes and
unresolved conflicts report an error; revision submodules display their commit ID.
Only one review tab per Neovim instance is supported. Concurrent instances of the
same review use last-writer-wins state; state writes are atomic.

## Test

From this checkout:

```sh
nvim --clean --headless -l tests/integration.lua
nvim --clean --headless -l tests/diff-render.lua
```

Set `DIFFREVIEW_SNACKS` to a Snacks checkout to include its actual picker in the
integration test. Tests create an isolated temporary Git repository.
