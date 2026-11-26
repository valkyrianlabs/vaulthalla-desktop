# Round out the Mac experience: Vaulthalla as a live node in the menu bar

Design for the epic of the same name (2026-11-26). It covers the menu bar item, running in the background, opening
at login, the fleet summary, favourites, native notifications, acting on findings (acknowledge, silence, remedy)
and filing a report. The server half is `design/health/findings.md` in `valkyrianlabs/vaulthalla-server`.

It is built in three stages. Stage 1 needs nothing from the server. Each section says which stage it belongs to.

## 1. What exists today (audited 2026-11-26, Desktop `313c96c`, server `400c7102`)

**Desktop**

- **One window, nothing else.** `VaulthallaApp` has a single `Window` scene and `Settings`. Closing the window
  quits the app. `docs/architecture.md` §3 promised "a menu bar extra shows health"; it was never built.
- **A background agent that is only for Finder.** `Vaulthalla --agent` (`BackgroundAgent.swift`,
  `SMAppService.agent`) runs while a vault is in Finder, as a read-only credential consumer. It keeps Finder fresh
  and removes domains that lost access. It shows nothing and notifies nobody.
- **No login item.** Nothing registers the app itself to open at login.
- **The fleet summary already exists.** `NodePulse` reads four things per node (`stats.dashboard.overview`,
  `stats.system.storage`, `stats.pricing.budget`, `sync.conflicts.summary`) plus per-vault activity.
  `NodeDigest` distils them and `FleetSummary` adds them up across nodes, counting a node that did not answer as
  "not reporting", never as healthy. All Nodes shows it.
- **Findings already have stable names.** Each attention item of the overview carries the server's `code`
  (`system.fuse.error_rate_high`), its card (`system.fuse`), the server's severity, a title and a message.
  `NodeDigest.Alert.id` is `card|code`.
- **Polling stops when the window is not visible.** `AppActivity` sets `NodeQueries.isActive`; a query polls
  only while a view observes it and the app is active.
- **One notification.** `RecoveryKeysNotifier` posts "N vault keys need backup" (opt-in, Settings ▸ 1Password)
  and makes itself the notification centre's only delegate.
- **Nothing is pushed.** `WsClient.unsolicitedMessages()` exists, and the server pushes `fs.changed`, but the app
  does not listen for anything about health.
- **Per node the registry stores** identity, endpoint, pairing state, routing hints and AI apps' pairings
  (`VHCore.Node`). View preferences (the transfer tuning switch) are in `UserDefaults`, by node id.
- **Signing.** Release builds are Developer ID (team `ZG2G6V7GLC`), hardened runtime, not sandboxed, with an App
  Group and keychain groups. Debug builds are ad hoc and share the bundle identifier `sh.vaulthalla.app`, so they
  share `UserDefaults` and notification settings with an installed release.
- **Updates.** Sparkle, standard user driver, started only in Release builds.
- **The windows are dark only** by design (`Theme.swift`).

**Server** (details in the server document)

- Severity is the backend's. Findings are computed on request and are not stored.
- Nothing can be acknowledged or silenced except cost alerts (`pricing.notifications.ack`).
- `stats.dashboard.severity` is a four-field answer cheap enough to ask often.
- Operator email alerting has its own repeat suppression, keyed on the system health status, not on findings.
- Agents reach a node through the CLI's command book (MCP), which has an exclusion list, and scoped devices are
  held to a per-command effect ceiling on the ws.

## 2. The menu bar item (stage 1)

**The item.** A `MenuBarExtra` in window style, shown by default, with a switch in Settings ▸ General.

**The icon** says one thing: the worst state across the paired nodes that are not muted.

| State | When | Icon |
| --- | --- | --- |
| Quiet | every paired node online and none reports errors | the Vaulthalla mark, template image |
| Attention | a node reports errors, or a paired node has been unreachable past the grace period, or a node revoked this Mac | the mark with a filled badge |
| Warnings only | warnings, no errors | the mark with a hollow badge |
| Not reporting | no node is paired, or none has answered yet | the mark, dimmed |

- The mark is a template image, so macOS draws it for a light or dark menu bar. The badge is part of the shape,
  not a colour, so the state reads without colour and with "Reduce transparency" or a tinted menu bar.
- "Unknown is never green": before the first answer the icon is the dimmed "not reporting" state, not quiet.
- Acknowledged and silenced findings do not count toward the icon (stage 2). They stay listed in the panel.

**The panel** (a 340-point-wide window under the item, dark like the app):

1. **Header.** One sentence for the fleet ("3 nodes, all healthy", "1 node needs attention", "2 of 3 nodes
   online"), when it was last checked, and a refresh button.
2. **Totals**, only what adds up: nodes online, storage used, open sync conflicts, spend this month (when any
   node tracks cost).
3. **Needs attention.** Findings across nodes, most severe first, at most five with "and N more". Each row names
   the node and opens the app where the finding lives (`AppModel.open(_:on:)`). In stage 2 each row has a menu:
   Acknowledge, Silence, the finding's remedies, File a Report.
4. **Nodes.** Favourites first, then the rest in sidebar order, at most eight with "Show all in Vaulthalla". A row
   shows the status dot, the name, and one line (health in the server's words, or why it is not connected).
   Clicking opens the node's Overview. A row menu jumps to Files, Sync Conflicts, Cost and Devices.
5. **Waiting on you.** Shown only when there is something: vault keys that need backup, a node that needs pairing
   again, an update ready to install.
6. **Footer.** Open Vaulthalla, Add Node…, Settings…, Quit Vaulthalla.

Everything in the panel is a figure a node reported or a state the app is in. Nothing is estimated.

## 3. Running in the background (stage 1)

- **Closing the window no longer quits** while the menu bar item is shown. The app keeps its sessions, so it stays
  the credential owner and keeps watching the nodes. Quit is ⌘Q or the panel's Quit.
- **No Dock icon without a window.** When the last window closes, the app becomes an accessory (menu bar only).
  Opening the window from the panel, the Dock, Spotlight or a notification makes it a regular app again.
- **Turning the menu bar item off** restores today's behaviour exactly: closing the window quits. Opening at
  login is then unavailable, because the app would have no visible presence.
- **"Keep me signed in" off** still signs out on quit and at logout, as today. Closing the window is not quitting.
- **The Finder agent is unchanged.** It still runs while a vault is in Finder and still covers the time the app is
  not running. Folding it into the background app is later work, not this epic.
- **Polling in the background is slow and cheap.** A new `FleetMonitor` owns it:
  - every 60 seconds per online node it asks `stats.dashboard.severity` (four numbers);
  - only when that answer differs from the last one does it fetch the full overview and compare findings;
  - sync conflicts and storage are refreshed every five minutes;
  - with the window visible, the views poll as they do today and the monitor reads the same cache.
  Stage 2 replaces the 60-second question with a push (`health.changed`) where the node supports it, and keeps
  the poll as the fallback for older nodes.
- **Updates.** With no window open, Sparkle must not pop a dialog from nowhere. The app implements Sparkle's
  gentle reminders: a scheduled update that arrives in the background shows as "Update ready" in the panel and
  as one notification; clicking either opens Sparkle's normal dialog.

## 4. Open at login (stage 1)

- `SMAppService.mainApp`, so Vaulthalla appears under System Settings ▸ General ▸ Login Items ▸ Open at Login,
  where the person can remove it like any other app.
- **On by default.** The first launch of a Release build registers it once and remembers that it did. It is
  never registered again on its own: if the person removes it, in the app or in System Settings, it stays off.
- **The switch shows the system's truth.** Settings reads `SMAppService.mainApp.status` each time it appears and
  when the app becomes active. `requiresApproval` is shown as "Turned off in System Settings" with a button that
  opens Login Items.
- **A login launch opens no window.** macOS marks the launch event (`keyAELaunchedAsLogInItem`); the app then
  starts as an accessory with only the menu bar item. A normal launch opens the window as today.
- **Debug builds never register by default** and never record that the default was applied, because they share
  preferences with an installed release and would leave a login item pointing into a build folder.

## 5. Favourites (stage 1)

- A star on a node: in the sidebar's context menu, on the All Nodes card, and in the panel's row menu.
- Favourites are listed first in the panel and marked in the sidebar. The sidebar's order stays the person's own.
- Stored in `UserDefaults` by node id (`NodePreferences`), with the per-node notification mute. They are view
  preferences of this Mac, not credentials, so they stay out of the registry and work while this app is a
  credential consumer. Removing a node removes its entries.

## 6. Notifications (stage 1, extended in stage 2)

One `NotificationHub` owns the notification centre: its delegate, the categories, permission and routing a click
to the right place. `RecoveryKeysNotifier` posts through it instead of owning the delegate.

**Permission** is asked once, the first time the menu bar item is shown in a build with a bundle, with the reason
in plain words in Settings. Denied permission is shown in Settings with a button to System Settings; the app
never asks twice.

**What notifies**

| Class | Fires when | Default | Sound | Click opens |
| --- | --- | --- | --- | --- |
| `node.unreachable` | a paired node has been offline for 2 minutes while this Mac itself has a network | on | yes | the node's Overview |
| `node.reachable` | a node whose outage was notified is back | on | no | the node's Overview |
| `node.revoked` | a node revoked this Mac, or its session says only pairing again helps | on | yes | the node, with Pair Again |
| `node.incompatible` | a node's protocol range no longer overlaps this build's | on | no | the node's Overview |
| `health.error` | a finding with error severity appears on a node | on | yes | where the finding lives |
| `health.warning` | a finding with warning severity appears | off | no | where the finding lives |
| `health.cleared` | every error that was notified on a node has cleared | on | no | the node's Overview |
| `sync.conflicts` | a node's open conflict count rises | on | no | Sync Conflicts |
| `keys.backup` | vault keys need backup (the existing notification) | as today (opt-in) | yes | Recovery Keys |
| `app.update` | an update arrived while no window was open | on | no | the update dialog |

**What never notifies:** anything while the window is frontmost and showing that node (the screen already says
it); a node that is not paired; a figure that is merely loading; info-level findings; a node the person muted.

**How repeats are suppressed**

- **One notification per thing.** Each has a stable identifier (`<node>|<class>|<finding code>`), so a second post
  replaces the first in Notification Centre instead of stacking.
- **A finding notifies once per occurrence.** While it stays active it is not repeated. When it clears and returns
  within 30 minutes it is treated as the same occurrence (flapping).
- **Bursts are grouped.** More than three new findings on one node in one check become a single "4 new problems
  on Studio" notification.
- **Reachability has a grace period** (2 minutes) and is held back entirely while this Mac has no network, is
  waking from sleep (first 30 seconds), or the node is restarting for an update it announced.
- **A relaunch is not news.** What was already notified is remembered on disk (`notified.json` next to the node
  list, node ids and finding codes only), so starting the app does not replay every open finding. The first check
  after a launch notifies only what is new since then.
- **Warnings are off by default** because one warning class (`system.operations.active_work`) fires during
  every upload. Stage 2 lets the server say which classes are worth a notification, and then warnings follow the
  server's hint instead of one switch.

**Settings ▸ Notifications** (new tab): a master switch, one switch per row of the table above, per-node mute,
and the permission state.

**Stage 2 adds** notification actions (Acknowledge, Silence for a day, the finding's first remedy, Open), each
of which runs the same server command as the panel's menu, and stops notifying for findings the server reports as
acknowledged or silenced, by anyone, on any Mac or in the console.

## 7. Acting on findings (stage 2)

The state is the server's, so the console and every Mac agree. The server document defines it. Desktop's part:

- **Reads** `health.findings.list`: every active finding with its class, severity, state (active, acknowledged,
  silenced), who set that and until when, whether a notification is worth it, and its remedies.
- **Acknowledge** and **Silence** in the panel, on All Nodes, in a node's Overview and on a notification. Silence
  asks for how long (1 hour, 24 hours, 7 days, until turned back on). Both are refused by the server unless the
  paired account has the permission; Desktop then shows them disabled with the reason.
- **A Silenced list** in each node's Overview: class, who, when, until, and "Turn back on".
- **Remedies** are whatever the server lists for the finding. Each is one existing command or a place to open.
  Desktop runs a command through `NodeQueries.perform`, so the usual confirmation sheet and permission errors
  apply. It has no remedy logic of its own.
- **Agents cannot do any of this** through Desktop: the MCP bridge offers no tool for it, and the server refuses
  the commands on agent paths (server document §7).

## 8. Filing a report (stage 3)

Decided by the maintainer (2026-11-26): a report goes to his own service, vaulthalla.cloud, directly, and only when
the person chooses to send it; the service may open a draft item for triage in a private project. The contract
both ends build to is `docs/design/report-intake.md` in valkyrianlabs/vaulthalla-cloud (`vh-report/1`). This
section is Desktop's half.

**Where a report starts.** Any finding (panel, Overview, a notification's action), any error sheet, and Help ▸
Report a Problem…. A notification already carries what a report about it needs: the node, and the finding's class,
severity, card, title and message.

**What it builds.** One report in the `vh-report/1` form, shown to the person before anything else can happen:

- the summary: product and version, platform, what the report is about, how often and since when;
- each piece of evidence as readable text:
  - `finding.json`: the finding as the node reported it (class, severity, message, card, metric);
  - `node.json`: the node's Vaulthalla version, protocol range, health overview and the class of route to it;
  - `desktop.json`: app version and build, macOS version, Mac model, the settings that matter;
  - `log.txt`: this app's own log lines from the last 15 minutes;
- what was removed, by kind and count;
- an optional note in the person's own words.

**Redaction (`vh-redact/1`), before it is shown**, so what the person reads is exactly what would leave:

- Replaced with labels that are stable within the one report: node, vault, user and device names; host names;
  IP addresses; email addresses; installation, node and device ids (`node-1`, `vault-3`, `addr-2`).
- Never collected in the first place: file contents, file and folder names and paths, keys, tokens, passwords,
  pairing codes, certificates and key pins.
- Evidence is built from chosen, typed fields. Text that comes from elsewhere (a node's message, log lines) goes
  through the pattern rules as well.
- Tested with seeded secrets: names, addresses, tokens and paths are planted in the inputs, and the tests assert
  none of those bytes are in the output.

**What the person can do with it**

| Action | When | What happens |
| --- | --- | --- |
| Save… | always | The bundle is written as a folder or zip where they choose. |
| Copy Summary | always | The summary text goes to the clipboard. |
| Send to Valkyrian Labs | only while this Mac is linked to Vaulthalla Cloud | One signed request (`POST /v1/reports`) from this Mac's own cloud identity. The answer's reference (`VHR-…`) is shown and kept with the saved copy. |

- **Sending is a choice made each time.** There is no automatic sending and no setting for it.
- **An unlinked Mac is never told about sending.** The button is absent, not disabled, so nothing in the app
  describes the cloud as available to someone who cannot use it. They keep Save and Copy.
- **A refusal is shown as it is**: not linked any more, too many reports today, or the service found something that
  must not be in a report (which is a bug in this app; the bundle stays local and the message says so).
- Nothing else in the app makes a network call for a report: building, viewing, saving and copying are local.

## 9. What is deliberately not in this epic

- The Finder agent taking over credential ownership, or being merged into the background app.
- A command palette (⌘K), also promised in `docs/architecture.md` §3.
- Widgets, Focus filters, Shortcuts actions.
- iOS or any second client.

## 10. Proof

- Unit tests for the fleet state, the notification decisions (first check, repeats, flapping, grouping, grace
  period, mute), the login-item state machine and favourites, all in `VHNodes`/`VHCore` so they run under
  `swift test`.
- The app target built as CI builds it.
- **Seen running**, with screenshots in light and dark menu bars: the item in each state, the panel, the Settings
  tabs, the login item listed in System Settings, and a delivered notification.
- Stage 2: a live check against a private daemon on dev (`docs/interop-testing.md`).

## 11. Stage 1 as built

**Where it lives**

| Piece | Code |
| --- | --- |
| The item's state | `Sources/VHNodes/FleetStatus.swift` |
| What notifies, and what never repeats | `Sources/VHNodes/FleetNotifier.swift` |
| Favourites and mutes | `Sources/VHNodes/NodePreferences.swift` |
| Open at login (the default and the switch) | `Sources/VHNodes/LoginItem.swift`, `App/Vaulthalla/App/MainAppLoginItem.swift` |
| The background check | `NodePulse.checkHealth()`, `App/Vaulthalla/MenuBar/FleetMonitor.swift` |
| The icon, the panel | `App/Vaulthalla/MenuBar/MenuBarIcon.swift`, `MenuBarPanel.swift` |
| The window, the Dock icon, a background launch | `App/Vaulthalla/MenuBar/MainWindow.swift`, `App/Vaulthalla/App/AppDelegate.swift` |
| The notification centre | `App/Vaulthalla/App/NotificationHub.swift` |
| Update reminders | `UpdateReminders` in `App/Vaulthalla/App/Updates.swift` |
| Settings | `SettingsView.swift` (Menu Bar section), `NotificationsSettingsView.swift` |

**Two things worth knowing before changing it**

- `MenuBarExtra(isInserted:)` must not be given the `@AppStorage` binding directly. SwiftUI writes the item's
  visibility back on every update of the app's scenes; with `@AppStorage` that write starts another update even when
  nothing changed, the app spins at 100% CPU and the item never appears. `VaulthallaApp.menuBarItemInserted` writes
  only on a real change.
- On current macOS the item's clicks are delivered by the system, and its button has no action. The panel cannot be
  opened from code, so seeing it open under the item takes a real click. Everything else has a DEBUG hook
  (`MenuBarDebug`): the panel and both Settings tabs rendered to PNG, every icon state on a light and a dark bar,
  and a report of what the running app is (background launch, Dock icon or not, windows, where the item is).

**Development builds** share the app's identifier and preferences with an installed release. So they never apply
"open at login" by default, never ask for notification permission at launch (only from Settings), and previews keep
favourites, mutes and notification switches in a throwaway preferences suite.

