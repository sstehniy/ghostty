# Pinned and snoozed sidebar tabs

In the macOS vertical sidebar, open a tab's context menu to **Pin Tab**, **Snooze**, or **Wake Tab**. Pinned tabs stay above ordinary tabs. Snoozed tabs live in a collapsible shelf at the bottom. Each window has its own sections.

Snoozing removes a pin and does not stop running programs. Normal tab shortcuts skip snoozed tabs; search still finds them. Opening a snoozed tab does not cancel its deadline. Snoozing the selected tab switches to another ordinary or pinned tab, or creates a new shell if none remain.

The presets are one hour, tomorrow morning, and next Monday. Set the morning hour in **Snooze > Morning Time**, or choose **Custom** for a date and time. Monday always means the following Monday, even on Monday morning. Calendar choices resolve in the current time zone when chosen; changing time zones later does not move the deadline.

When due, a tab returns to the top of the ordinary section with a **Woke** badge until visited. Deadlines do not steal focus, start dormant agents, launch Ghostty, wake the computer, or send notifications. Errors, approvals, and output do not end a snooze early.

## Saving and reopening

Pinned and snoozed tabs are saved independently of `window-save-state`, including when it is `never`. Changes are saved as they happen and refreshed periodically for best-effort crash recovery. Layout, directories, titles, colors, and supported agent-session references are saved, not raw terminal output or process memory.

Quitting preserves saved tabs. When reviewing running windows before Quit, no window closes until every confirmation is approved; cancelling leaves them running.

Closing a tab or its whole window removes it from the explicit store. **Close Other Tabs** and **Close Tabs to the Right** protect pinned and snoozed tabs. Unpinning or waking returns a tab to normal restoration rules. Overdue tabs are first brought back on reopening before their explicit saved record is removed.

On reopening, unselected saved tabs have dormant panes. Visiting a tab starts all of its panes; the initially selected tab counts as visited. Ordinary shells start fresh. Unsupported programs, including SSH and tmux sessions, are not replayed.

The explicit store is `saved-tabs.json` under Ghostty's bundle-specific directory in `~/Library/Application Support`. It contains local paths and session identifiers. It does not copy transcripts or credentials. Unreadable archives are not overwritten; a save error is shown instead.

## Agent conversations

Local Claude Code, Codex, and Pi can resume the exact conversation when launched through Ghostty's integrated shell. Ghostty supplies private command shims and per-invocation integration files in its own Application Support directory. It does not edit global agent configuration.

- Claude Code reports its session ID through an invocation-local `SessionStart` hook.
- Pi reports its session file and native conversation ID through an invocation-local extension. Ghostty checks that the file still contains that conversation before resuming; a missing or replaced file cannot silently create a new conversation.
- Codex runs standalone (`--no-daemon`) so Ghostty can identify its writable root rollout descriptor. This requires a Codex version with that option, such as 0.166.0. Read-only history and subagent rollouts are excluded.

The integrations preserve supported model, profile, configuration-directory, and permission/sandbox choices. They do not save API keys, original prompts, arbitrary config overrides, or one-shot commands, and do not send a new prompt on resume.

An agent already running before these helpers were installed needs restarting through the integrated shell. Absolute-path launches, shell functions that bypass the shims, disabled shell integration, unsupported launch options, or missing session metadata may prevent exact restoration. The sidebar warns before quitting when an exact ID is unavailable. Ghostty never substitutes the newest conversation in a directory. On reopening, failures are visible in the pane; an available resume command can be copied for manual recovery.

The horizontal native tab bar retains saved state but does not promise to hide snoozed tabs. The section UI is specific to the vertical sidebar.
