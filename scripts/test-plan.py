#!/usr/bin/env python3
"""Rebuild docs/TESTING.csv: one test per agent and feature from the app's own
capabilities (`ullage harnesses --csv`), then context tools, surfaces, CLI and
install. Keeps Status, Tested on and Notes already filled in.

    swift build && scripts/test-plan.py
"""
import csv, io, os, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'docs', 'TESTING.csv')

REST = [
    ('Context tools', 'rtk: install', 'Context tools page → Install rtk…', 'Supported', 'Commands shown first; run in Terminal; row says installed'),
    ('Context tools', 'rtk: in use', 'Start a new Claude Code session that uses it', 'Supported', 'Row shows rewrites and ≈ saved from its own log'),
    ('Context tools', 'rtk: switch off and on', 'Flip its switch, then Undo', 'Supported', 'Off from the next session; Undo restores settings exactly'),
    ('Context tools', 'rtk: uninstall', 'Uninstall rtk…', 'Supported', 'Its own uninstall commands run; row offers Install again'),
    ('Context tools', 'Tokenade: install', 'Context tools page → Install Tokenade…', 'Supported', 'Commands shown first; run in Terminal; row says installed'),
    ('Context tools', 'Tokenade: in use', 'Start a new Claude Code session that uses it', 'Supported', 'Row shows rewrites and ≈ saved from its own log'),
    ('Context tools', 'Tokenade: switch off and on', 'Flip its switch, then Undo', 'Supported', 'Off from the next session; Undo restores settings exactly'),
    ('Context tools', 'Tokenade: uninstall', 'Uninstall Tokenade…', 'Supported', 'Its own uninstall commands run; row offers Install again'),
    ('Context tools', 'caveman: install', 'Context tools page → Install caveman…', 'Supported', 'Commands shown first; run in Terminal; row says installed'),
    ('Context tools', 'caveman: in use', 'Start a new Claude Code session that uses it', 'Supported', 'Row shows tokens/reply with vs without'),
    ('Context tools', 'caveman: switch off and on', 'Flip its switch, then Undo', 'Supported', 'Off from the next session; Undo restores settings exactly'),
    ('Context tools', 'caveman: uninstall', 'Uninstall caveman…', 'Supported', 'Its own uninstall commands run; row offers Install again'),
    ('Context tools', 'Headroom: install', 'Context tools page → Install Headroom…', 'Supported', 'Commands shown first; run in Terminal; row says installed'),
    ('Context tools', 'Headroom: in use', 'Start a new Claude Code session that uses it', 'Supported', 'Row shows calls, or idle when loaded but unused'),
    ('Context tools', 'Headroom: switch off and on', 'Flip its switch, then Undo', 'Supported', 'Off from the next session; Undo restores settings exactly'),
    ('Context tools', 'Headroom: uninstall', 'Uninstall Headroom…', 'Supported', 'Its own uninstall commands run; row offers Install again'),
    ('Context tools', 'Serena: install', 'Context tools page → Install Serena…', 'Supported', 'Commands shown first; run in Terminal; row says installed'),
    ('Context tools', 'Serena: in use', 'Start a new Claude Code session that uses it', 'Supported', 'Row shows lookups and ≈ size returned'),
    ('Context tools', 'Serena: switch off and on', 'Flip its switch, then Undo', 'Supported', 'Off from the next session; Undo restores settings exactly'),
    ('Context tools', 'Serena: uninstall', 'Uninstall Serena…', 'Supported', 'Its own uninstall commands run; row offers Install again'),
    ('Context tools', 'codegraph: install', 'Context tools page → Install codegraph…', 'Supported', 'Commands shown first; run in Terminal; row says installed'),
    ('Context tools', 'codegraph: in use', 'Start a new Claude Code session that uses it', 'Supported', 'Row shows lookups and ≈ size returned'),
    ('Context tools', 'codegraph: switch off and on', 'Flip its switch, then Undo', 'Supported', 'Off from the next session; Undo restores settings exactly'),
    ('Context tools', 'codegraph: uninstall', 'Uninstall codegraph…', 'Supported', 'Its own uninstall commands run; row offers Install again'),
    ('Context tools', 'claude-context: install', 'Context tools page → Install claude-context…', 'Supported', 'Commands shown first; run in Terminal; row says installed'),
    ('Context tools', 'claude-context: in use', 'Start a new Claude Code session that uses it', 'Supported', 'Row shows lookups and ≈ size returned'),
    ('Context tools', 'claude-context: switch off and on', 'Flip its switch, then Undo', 'Supported', 'Off from the next session; Undo restores settings exactly'),
    ('Context tools', 'claude-context: uninstall', 'Uninstall claude-context…', 'Supported', 'Its own uninstall commands run; row offers Install again'),
    ('Context tools', 'claude-mem: install', 'Context tools page → Install claude-mem…', 'Supported', 'Commands shown first; run in Terminal; row says installed'),
    ('Context tools', 'claude-mem: in use', 'Start a new Claude Code session that uses it', 'Supported', 'Row shows ≈ injected at session start'),
    ('Context tools', 'claude-mem: switch off and on', 'Flip its switch, then Undo', 'Supported', 'Off from the next session; Undo restores settings exactly'),
    ('Context tools', 'claude-mem: uninstall', 'Uninstall claude-mem…', 'Supported', 'Its own uninstall commands run; row offers Install again'),
    ('Context tools', 'Custom tool from JSON', 'Add a descriptor to ~/.config/ullage/tools/, run ullage tools', 'Supported', 'Listed as your file; detected in sessions'),
    ('Menu bar & popover', 'Menu bar percentage', 'Use Claude Code until the window fills', 'Supported', 'Percentage rises; warning glyph at 85%'),
    ('Menu bar & popover', 'Popover glance', 'Click the menu bar item', 'Supported', 'Headline, bar, chart, one line per section'),
    ('Menu bar & popover', 'Section rows open pages', 'Click each popover row', 'Supported', 'Main window opens on that page'),
    ('Menu bar & popover', 'Explain sheet', 'Click Explain', 'Supported', 'Sections with collapsible questions'),
    ('Menu bar & popover', 'Open in Claude / Codex', 'Click the link on a Remote Control or Codex session', 'Supported', 'Opens the session in Claude or the Codex app'),
    ('Menu bar & popover', 'Gauge notice', 'Pick a Cursor or Aider session', 'Supported', 'Notice replaces the gauge; says why'),
    ('Main window', 'Overview', 'Open Ullage', 'Supported', 'Chart and summary cards for every section'),
    ('Main window', 'Context', 'Open the Context page', 'Supported', 'Treemap explorer; drill into Tool results'),
    ('Main window', 'Session', 'Open the Session page', 'Supported', 'Rows, cache rebuilds, and What X records for non-Claude agents'),
    ('Main window', 'Agents', 'Open on a session with subagents', 'Supported', 'Each agent with its own window'),
    ('Main window', 'History', 'Open History', 'Supported', 'Activity per day by project, model or effort'),
    ('Main window', 'Plan limits', 'Turn on Check Claude plan limits', 'Supported', 'Claude and Codex limits as % left'),
    ('Main window', 'Session picker', 'Pick another session', 'Supported', 'Every page follows it'),
    ('Phone page', 'Overview and pages', 'Open the served page on the phone; tap each row', 'Supported', 'Pages slide in; Back closes them'),
    ('Phone page', 'Context tools switch', 'Flip a switch on the phone', 'Supported', 'Changes on the Mac; Undo works'),
    ('Phone page', 'Install from phone', 'Install a tool from the phone', 'Supported', 'Runs in Terminal on the Mac; sign-in installs are refused'),
    ('Phone page', 'Alerts', 'Subscribe, then ullage push --test', 'Supported', 'Notification arrives'),
    ('Phone page', 'What X records', 'Open a non-Claude session on the phone', 'Supported', "Section lists what the agent doesn't record"),
    ('Command line', 'ullage backfill', 'Run ullage backfill', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage sessions', 'Run ullage sessions', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage harnesses', 'Run ullage harnesses', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage tools', 'Run ullage tools', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage savers', 'Run ullage savers', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage composition <session>', 'Run ullage composition <session>', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage agents <session>', 'Run ullage agents <session>', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage rebuilds --days 7', 'Run ullage rebuilds --days 7', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage limits --fetch', 'Run ullage limits --fetch', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage otlp --dry-run', 'Run ullage otlp --dry-run', 'Supported', 'Sane output, no errors'),
    ('Command line', 'ullage serve', 'Run ullage serve', 'Supported', 'Sane output, no errors'),
    ('Install & release', 'Homebrew fresh install', 'brew install sturdynut/tap/ullage on a clean Mac', 'Supported', 'Builds from source; app links into /Applications'),
    ('Install & release', 'Homebrew upgrade', 'brew update && brew upgrade sturdynut/tap/ullage', 'Supported', 'Upgrades to the latest tag'),
    ('Install & release', 'brew services', 'brew services start ullage', 'Supported', 'Phone page served on 127.0.0.1:7878'),
    ('Install & release', 'install-app.sh', 'scripts/install-app.sh', 'Supported', 'Quits the running app, installs, relaunches'),
]

matrix = subprocess.run([os.path.join(ROOT, '.build/debug/ullage'), 'harnesses', '--csv'],
                        check=True, capture_output=True, text=True).stdout
rows = list(csv.reader(io.StringIO(matrix)))
header, rows = rows[0], rows[1:]
rows += [list(r) + ['', '', ''] for r in REST]

kept = {}
if os.path.exists(OUT):
    for r in csv.DictReader(open(OUT, newline='')):
        kept[(r['Area'], r['Item'])] = (r.get('Status', ''), r.get('Tested on', ''), r.get('Notes', ''))
with open(OUT, 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(header)
    for r in rows:
        r[5:8] = kept.get((r[0], r[1]), ('', '', ''))
        w.writerow(r)
print(f'{len(rows)} tests in {OUT}')
