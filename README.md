# chrome-agent

Consent-gated Chrome debugging for opencode on Ubuntu, controlled by a
[KySettings](https://github.com/1LKY3/kysettings) toggle.

`chrome-agent` lets an AI agent (opencode and any other MCP client) inspect and
drive a Chrome browser through the DevTools Protocol — list tabs, navigate,
evaluate JavaScript, read console output and capture screenshots — only while
the user has explicitly enabled **Privacy → Agent → Agent Chrome Access** in
KySettings. The enable flag is the security boundary: with the toggle off the
MCP server refuses every call, the debug port is closed, and the mirrored
profile copy is wiped from disk.

## Why a mirror

Chrome 136 and later ignore `--remote-debugging-port` when the default Chrome
data directory is used. This is deliberate anti-cookie-theft hardening by
Google; it cannot be bypassed. To give an agent access to the user's real
logins, `chrome-agent` mirrors the personal profile into a non-standard data
directory at enable time. The mirror keeps cookies, logins and extensions and
excludes caches and history. It is wiped again on disable.

The browsers run under XWayland (`--ozone-platform=x11`) so window geometry can
be read and restored programmatically — see "Anchored window restore" below.

## Components

| File | Purpose |
| --- | --- |
| `chrome-agent.sh` | Launcher/control: `enable`, `disable`, `refresh`, `status`, `restart` |
| `mcp_server.py` | MCP stdio server exposing the tools below |

### MCP tools

| Tool | Description |
| --- | --- |
| `chrome_status` | Toggle state, debug port, tab count |
| `chrome_tabs` | List open tabs (id, title, URL) |
| `chrome_navigate` | Navigate a tab and wait for load |
| `chrome_eval` | Evaluate JavaScript in a tab |
| `chrome_console` | Collect console messages/exceptions for a short window |
| `chrome_screenshot` | PNG screenshot of a tab |

## Quick start

```sh
install -d -m 700 ~/.local/share/chrome-agent
install -m 755 chrome-agent.sh ~/.local/share/chrome-agent/
install -m 755 mcp_server.py  ~/.local/share/chrome-agent/

# The toggle writes this flag; the MCP server only works while it exists.
~/.local/share/chrome-agent/chrome-agent.sh enable
~/.local/share/chrome-agent/chrome-agent.sh status
~/.local/share/chrome-agent/chrome-agent.sh disable
```

Register the MCP server with opencode (`~/.config/opencode/opencode.jsonc`):

```jsonc
{
  "mcp": {
    "chrome-agent": {
      "type": "local",
      "command": ["/usr/bin/python3", "/home/<user>/.local/share/chrome-agent/mcp_server.py"],
      "enabled": true,
      "timeout": 30000
    }
  }
}
```

`mcp_server.py` needs `websocket-client` (`apt install python3-websocket`).

## Lifecycle

1. **Enable** (`Agent Chrome Access` ON): mirrors the personal profile into
   `~/.config/chrome-agent/profile`, launches Chrome there with the debug port
   bound to `127.0.0.1:9223` and the XWayland flag, and writes the enable flag.
2. **Refresh All Browsers** (KySettings button): quits the personal Chrome
   gracefully, re-syncs the profile (session + logins), marks the profile as a
   clean exit, and relaunches the debug browser with `--restore-last-session`
   and `--hide-crash-restore-bubble`, so the same sites return without the
   "Restore pages?" prompt.
3. **Disable** (toggle OFF): captures the open sites, closes the debug browser,
   wipes the mirror, and reopens the personal Chrome with those sites.

## Anchored window restore

The user anchors windows to monitor halves with Super+Left / Super+Right.
Before every quit the launcher records each visible Chrome window's bounds with
`xdotool` into `~/.config/chrome-agent/layout.tsv`; after every relaunch it
matches windows by title and moves/resizes them back to the recorded anchors.
Because Wayland clients cannot be positioned (or read) by other processes, the
browsers for this loop run under XWayland:

```sh
# optional user-level override so dock launches also use X11
sed 's|^Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable --ozone-platform=x11|' \
  /usr/share/applications/google-chrome.desktop \
  > ~/.local/share/applications/google-chrome.desktop
```

The first cycle needs one manual arrangement; afterwards the anchors restore
automatically. Delete the override to return Chrome to Wayland.

## KySettings integration

KySettings owns the consent UI. The pieces added to `kysettings.py` (Privacy
page, "Agent" group):

```python
CHROME_AGENT_SCRIPT = pathlib.Path.home() / ".local/share/chrome-agent/chrome-agent.sh"
CHROME_AGENT_FLAG = pathlib.Path.home() / ".config/chrome-agent/enabled"

chrome_agent_row = Adw.SwitchRow()
chrome_agent_row.set_title("Agent Chrome Access")
chrome_agent_row.connect("notify::active", self.on_chrome_agent_toggle)

refresh_row = Adw.ActionRow()
refresh_row.set_title("Refresh All Browsers")
refresh_row.set_subtitle(self.REFRESH_BROWSERS_SUBTITLE)
self.refresh_button = Gtk.Button(label="Refresh", valign=Gtk.Align.CENTER)
self.refresh_button.connect("clicked", self.on_refresh_browsers)
refresh_row.add_suffix(self.refresh_button)
```

The toggle runs `chrome-agent.sh enable|disable` asynchronously with
`Gio.Subprocess`; the Refresh button runs `chrome-agent.sh refresh`. The
Refresh button is insensitive while the toggle is off. KySettings also carries
its own updater, so users install these controls through
`https://kysettings.dustforge.com`.

## Safety model

- The `enabled` flag file is checked on **every** MCP tool call. Toggling off
  revokes access instantly, mid-session, with no opencode restart.
- The debug port is bound to `127.0.0.1` only.
- Disabling wipes the mirrored credentials from disk.
- The mirror is a snapshot; logins made in the personal browser after enable
  appear on the next refresh. Both browsers share session tokens, so a rare
  single-session site may sign one side out.
- `chrome://` pages, the Chrome Web Store and other extensions' pages cannot be
  attached.
- Chrome shows its own debugging indicator while the port is active.

## Status

Experimental. Verified on Ubuntu 26.04 with Google Chrome 154 (Wayland session,
XWayland windows) and KySettings 0.4.6.
