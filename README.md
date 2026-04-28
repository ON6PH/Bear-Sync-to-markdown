# Bear Sync To Markdown

Incremental Bear → Markdown sync using the new bearcli (Bear 2.8 beta).

Exports your Bear notes as individual .md files whenever the Bear database changes. Only modified or new notes are exported. Deleted notes are cleaned up automatically. Attachments are saved to a central attachments/ folder with links rewritten accordingly.

Optionally mirrors the output to a secondary location (Nextcloud, external drive) via rsync.

![Bear sync pipeline](Bear%20sync%20pipelinge%20diagram.png)

---

## How it works

1. **fswatch** monitors the Bear SQLite database using --monitor=poll_monitor
2. A **Launch Agent** keeps fswatch running in the background, starting automatically at login
3. On every change, bear_sync.sh runs:
 - Fetches all active notes via bearcli list
 - Compares each note’s hash against a local state file
 - Exports only notes whose hash has changed
 - Saves attachments to attachments/ and rewrites Markdown links
 - Removes .md files for notes deleted or moved to trash
 - Runs rsync to mirror the backup to a secondary location (if available)

## Output structure

```
~/BearBackup/
  notes/
    My note.md
    Another note.md
    attachments/
      image.png
      document.pdf
  .note_hashes.json     ← internal state, do not edit
  bear_sync.sh          ← sync script
```

## Requirements

- Bear 2.8 beta — bearcli is bundled inside Bear.app
- [fswatch](https://github.com/emcrisostomo/fswatch) via Homebrew
- Python 3 (ships with macOS)

---

## Installation

1. Install fswatch and create a symlink

```bash
brew install fswatch
sudo ln -sf /opt/homebrew/bin/fswatch /usr/local/bin/fswatch
```

The symlink is needed because Launch Agents run in a minimal environment without Homebrew in PATH.

### 2. Create the backup folder and copy the script

```bash
mkdir -p ~/BearBackup
cp bear_sync.sh ~/BearBackup/bear_sync.sh
chmod +x ~/BearBackup/bear_sync.sh
```

### 3. Configure the script

Open `~/BearBackup/bear_sync.sh` and adjust the variables at the top of the Python block:

```python
BACKUP_DIR  = Path.home() / "BearBackup" / "notes"   # local backup location
SYNC_MOUNT  = Path("/Volumes/Nextcloud")               # secondary sync mount point
SYNC_DIR    = SYNC_MOUNT / "Documents" / "Bear" / "notes"  # secondary sync folder
```

Set `SYNC_DIR = None` to disable rsync entirely.

### 4. Install the Launch Agent

```bash
cp com.bear.sync.plist ~/Library/LaunchAgents/com.bear.sync.plist
launchctl load ~/Library/LaunchAgents/com.bear.sync.plist
```

### 5. Verify it's running

```bash
launchctl list | grep bear
```

You should see a PID next to `com.bear.sync`. If the PID column shows `-`, the agent is loaded but not running — check the fswatch path.

### 6. Test it

Edit a note in Bear and check that a `.md` file appears in `~/BearBackup/notes/` within a few seconds.

---

## Managing the Launch Agent

```bash
# Check status
launchctl list | grep bear

# Restart
launchctl unload ~/Library/LaunchAgents/com.bear.sync.plist
launchctl load ~/Library/LaunchAgents/com.bear.sync.plist

# Run manually
~/BearBackup/bear_sync.sh
```

---

## Full resync

If your Mac has been offline for a while or you want to rebuild the backup from scratch:

```bash
rm ~/BearBackup/.note_hashes.json
~/BearBackup/bear_sync.sh
```

---

## Why poll_monitor?

The default FSEvents monitor in fswatch does not work on files inside macOS `Group Containers`. The `--monitor=poll_monitor` flag uses polling instead, which works reliably on the Bear database.

## Why hash-based?

`bearcli` exposes a `hash` field per note. Comparing hashes is more reliable than comparing timestamps, especially with iCloud sync where modification times can be unpredictable. A note is only exported if its hash has changed since the last run.

## Why rsync instead of writing directly to the secondary location?

The local `~/BearBackup/notes/` folder is always the source of truth. If the secondary location (e.g. a network drive) is unavailable, the sync is skipped gracefully and picks up on the next run. This avoids partial writes and state corruption.

---

## Notes

- Encrypted Bear notes are not accessible via `bearcli` and will be skipped
- Bear's built-in archive is not included — only active notes are exported
- Filenames are capped at 80 characters to avoid OS filename length limits
- The `.note_hashes.json` state file maps note IDs to their last-seen hash and title

---

## License

MIT
