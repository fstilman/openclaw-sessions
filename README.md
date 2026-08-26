# openclaw-sessions

An Emacs dashboard for named [OpenClaw](https://docs.openclaw.ai/) TUI
sessions. It launches sessions in a configurable Emacs terminal, reads lifecycle state from
`openclaw sessions --json`, sends completion notifications, and keeps a compact
summary in the mode line.

## Installation

Once the package is available from MELPA:

```elisp
(use-package openclaw-sessions
  :ensure t
  :commands (openclaw-sessions openclaw-sessions-start)
  :bind (("C-c o s" . openclaw-sessions)
         ("C-c o n" . openclaw-sessions-start)))
```

To install directly from the source repository, clone it and add the package
directory to `load-path`:

```sh
git clone https://github.com/fstilman/openclaw-sessions.git
```

```elisp
(use-package openclaw-sessions
  :load-path "~/dev/emacs-packages/openclaw-sessions"
  :commands (openclaw-sessions openclaw-sessions-start)
  :bind (("C-c o s" . openclaw-sessions)
         ("C-c o n" . openclaw-sessions-start)))
```

The package requires Emacs 27.1 or newer and the `openclaw` executable. VTerm
and Eat are optional; the built-in Term backend requires no extra package.

## Usage

- `M-x openclaw-sessions-start` asks only for a session name and opens
  `openclaw tui --session NAME` in a dedicated terminal buffer.
- `M-x openclaw-sessions` opens the dashboard.
- `RET` visits or attaches to the selected session.
- `m` marks its latest completion as reviewed.
- `u` marks it as unreviewed again.
- `n` starts a session.
- `g` refreshes immediately.
- `s` cycles globally between package-managed, direct, and all sessions. The
  dashboard and mode-line indicator always use the same scope.
- `t` shows recent `openclaw sessions tail` output.
- `q` closes the dashboard window.

Use a prefix argument with `openclaw-sessions-start` to select an agent
explicitly. The prompt provides standard completion over the agents returned
by `openclaw agents list --json`, while still accepting a new agent ID. The
resulting target is `agent:AGENT:NAME`.

## Working-directory semantics

The shell CWD is not the agent's working directory. OpenClaw sessions use the
workspace configured for their selected agent. The TUI only examines its CWD
to infer an agent when launched inside that agent's configured workspace.

Accordingly, this package does not use `project.el`, prompt for a directory, or
display directories in the dashboard. By default the TUI inherits the current
buffer's `default-directory`, preserving OpenClaw's native inference. Set a
fixed directory when deterministic selection is preferred:

```elisp
(setq openclaw-sessions-launch-directory "~/.openclaw/workspace")
```

Alternatively, set `openclaw-sessions-default-agent`; explicit agent selection
is clearer and does not depend on CWD:

```elisp
(setq openclaw-sessions-default-agent "main")
```

## Terminal backends

`openclaw-sessions-terminal-backend` controls where TUI sessions run. Its
default value, `auto`, selects VTerm, then Eat, then the built-in Term:

```elisp
(setq openclaw-sessions-terminal-backend 'auto)  ; vterm → eat → term
(setq openclaw-sessions-terminal-backend 'eat)   ; require Eat
(setq openclaw-sessions-terminal-backend 'term)  ; no optional dependency
```

Each built-in backend runs the OpenClaw executable directly. Eat and Term pass
its argument vector unchanged; VTerm receives an equivalently shell-quoted
command because that is the interface exposed by VTerm.

For another Emacs terminal integration, set the option to a function. It
receives `SESSION-NAME`, `EXECUTABLE`, `ARGUMENTS`, and `DIRECTORY`, and must
return the live terminal buffer:

```elisp
(defun my-openclaw-terminal (session-name executable arguments directory)
  ;; Create the terminal and start EXECUTABLE with ARGUMENTS in DIRECTORY.
  ;; Return its Emacs buffer.
  )

(setq openclaw-sessions-terminal-backend #'my-openclaw-terminal)
```

Returning a buffer preserves session tracking, `RET` navigation, and the
`managed` scope. Line-oriented `shell-mode` and plain Eshell are not supported
because `openclaw tui` requires terminal emulation. Eat's Eshell visual-command
integration can still be used through a custom launcher.

See the OpenClaw documentation for [TUI selection](https://docs.openclaw.ai/cli/tui),
[agent workspaces](https://docs.openclaw.ai/concepts/agent-workspace), and
[session worktrees](https://docs.openclaw.ai/concepts/managed-worktrees).

## Monitoring

Refreshes are asynchronous and never block Emacs. The default interval is ten
seconds because starting the OpenClaw CLI has non-trivial overhead. Customize
`openclaw-sessions-refresh-interval`, or set it to nil for manual refresh only.

The default dashboard scope includes only sessions launched or attached by the
package. Press `s` to inspect other recent OpenClaw sessions.

When a direct session changes from `RUNNING` to a terminal status, the
dashboard shows `●` in its **New** column. The marker means that the completion
has not yet been reviewed; it is not inferred from buffer visibility. Visiting
the session buffer—whether through `RET`, `switch-to-buffer`, Ibuffer, or a
completion UI—or viewing its tail with `t` clears it. Merely displaying the
buffer without selecting it does not. The `m` and `u` commands allow explicit
control. Existing completed sessions are not marked when monitoring starts:
only transitions observed by Emacs count as new.

Custom mode lines can include the public `openclaw-sessions-mode-line`
construct directly. It displays running (`▶`), successful (`✓`), and failed
(`!`) session counts, plus unreviewed completions (`●`), for
`openclaw-sessions-dashboard-scope`. Customize
`openclaw-sessions-mode-line-prefix` to change its left spacing.

## Tests

```sh
emacs -Q --batch \
  -L . -L test \
  -l test/openclaw-sessions-test.el \
  -f ert-run-tests-batch-and-exit
```

Run every local check with:

```sh
make test compile checkdoc package-lint
```

`package-lint` must be installed separately from MELPA.

## License

GNU General Public License version 3 or later. See [LICENSE](LICENSE).
