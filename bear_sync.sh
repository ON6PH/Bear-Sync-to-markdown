#!/bin/bash
# =============================================================================
# bear_sync.sh — Incremental Bear → Markdown sync
# =============================================================================
#
# PURPOSE:
#   Exports Bear notes as individual .md files to a backup folder.
#   Incremental: only changed or new notes are exported.
#   Deleted notes (including notes moved to trash) are removed from backup.
#
# OUTPUT STRUCTURE:
#   ~/BearBackup/
#     notes/
#       Note title.md          ← one .md file per note
#       attachments/           ← central folder for all attachments
#         image.png
#         document.pdf
#     .note_hashes.json        ← internal state file (do not edit)
#
# HOW IT WORKS:
#   - Fetches all active notes via bearcli list
#   - Compares the hash of each note against a saved state file
#   - Exports only notes whose hash has changed
#   - Saves attachments to attachments/ and rewrites links accordingly
#   - Removes .md files for notes no longer present in Bear
#   - Runs rsync to mirror the local backup to a secondary location
#
# REQUIREMENTS:
#   - Bear 2.8 beta or later (bearcli is bundled inside Bear.app)
#   - fswatch via Homebrew: brew install fswatch
#   - Symlink: sudo ln -sf /opt/homebrew/bin/fswatch /usr/local/bin/fswatch
#   - Python 3 (ships with macOS)
#
# TRIGGER:
#   Runs automatically via a Launch Agent (com.bear.sync) that uses fswatch
#   to monitor the Bear database for changes.
#
#   Launch Agent: ~/Library/LaunchAgents/com.bear.sync.plist
#   fswatch command:
#     /usr/local/bin/fswatch --monitor=poll_monitor -o \
#       "$HOME/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite" \
#       | xargs -n1 -I{} "$HOME/BearBackup/bear_sync.sh"
#
# CHANGE BACKUP DESTINATION:
#   Edit the BACKUP_DIR and SYNC_DIR variables below.
#   Example for Nextcloud:
#     BACKUP_DIR = Path.home() / "BearBackup" / "notes"
#     SYNC_DIR   = Path("/Volumes/Nextcloud") / "Documents" / "Bear" / "notes"
#
# MANUAL RUN:
#   ~/BearBackup/bear_sync.sh
#
# FULL RESYNC (reset state):
#   rm ~/BearBackup/.note_hashes.json && ~/BearBackup/bear_sync.sh
#
# =============================================================================

python3 << 'EOF'
import json, subprocess, re
from pathlib import Path

BEARCLI         = "/Applications/Bear.app/Contents/MacOS/bearcli"
BACKUP_DIR      = Path.home() / "BearBackup" / "notes"
ATTACHMENTS_DIR = BACKUP_DIR / "attachments"
STATE_FILE      = Path.home() / "BearBackup" / ".note_hashes.json"

# Secondary sync destination (e.g. Nextcloud, external drive)
# Set to None to disable rsync
SYNC_MOUNT      = Path("/Volumes/Nextcloud")
SYNC_DIR        = SYNC_MOUNT / "Documents" / "Bear" / "notes"

BACKUP_DIR.mkdir(parents=True, exist_ok=True)
ATTACHMENTS_DIR.mkdir(parents=True, exist_ok=True)

# Initialise state file if it doesn't exist
if not STATE_FILE.exists():
    STATE_FILE.write_text("{}", encoding="utf-8")

# Load saved hashes
saved_hashes = json.loads(STATE_FILE.read_text(encoding="utf-8"))

# Fetch all active notes via bearcli
result = subprocess.run(
    [BEARCLI, "list", "--format", "json", "--fields", "id,title,hash"],
    capture_output=True, text=True
)

if result.returncode != 0:
    print(f"bearcli error: {result.stderr}")
    exit(1)

notes = json.loads(result.stdout)
current_ids = {note["id"] for note in notes}

# ── Clean up: remove notes no longer in Bear ──────────────────────────────
removed = 0
for old_id, old_data in list(saved_hashes.items()):
    if old_id not in current_ids:
        old_title = old_data.get("title", old_id) if isinstance(old_data, dict) else old_id
        safe_title = (re.sub(r'[/\\:*?"<>|]', '-', old_title).strip() or old_id)[:80].strip()
        old_file = BACKUP_DIR / f"{safe_title}.md"
        if old_file.exists():
            old_file.unlink()
            print(f"  🗑️  Removed: {old_title}")
            removed += 1
        del saved_hashes[old_id]

# ── Export: new and changed notes ─────────────────────────────────────────
exported = 0
skipped  = 0

for note in notes:
    note_id   = note["id"]
    title     = note["title"]
    curr_hash = note["hash"]

    # Skip if hash hasn't changed
    saved = saved_hashes.get(note_id)
    saved_hash = saved.get("hash") if isinstance(saved, dict) else saved
    if saved_hash == curr_hash:
        skipped += 1
        continue

    # Fetch note content
    cat = subprocess.run(
        [BEARCLI, "cat", note_id, "--format", "json"],
        capture_output=True, text=True
    )

    if cat.returncode != 0:
        print(f"  ⚠️  Could not read '{title}' (locked?), skipping.")
        continue

    content = json.loads(cat.stdout).get("content", "")

    # Fetch attachments and save to central attachments folder
    att_result = subprocess.run(
        [BEARCLI, "attachments", "list", note_id, "--format", "json", "--fields", "filename"],
        capture_output=True, text=True
    )

    if att_result.returncode == 0 and att_result.stdout.strip() not in ("[]", ""):
        attachments = json.loads(att_result.stdout)
        for att in attachments:
            filename = att["filename"]
            att_path = ATTACHMENTS_DIR / filename

            save_result = subprocess.run(
                [BEARCLI, "attachments", "save", note_id, "--filename", filename],
                capture_output=True
            )

            if save_result.returncode == 0:
                att_path.write_bytes(save_result.stdout)
                print(f"    📎 Attachment saved: {filename}")
            else:
                print(f"    ⚠️  Could not save attachment '{filename}'.")

            # Rewrite link: ![](filename) → ![](attachments/filename)
            content = content.replace(f"]({filename})", f"](attachments/{filename})")

    # Safe filename (max 80 chars to avoid OS limits)
    safe_title = re.sub(r'[/\\:*?"<>|]', '-', title).strip() or note_id
    safe_title = safe_title[:80].strip()
    filepath = BACKUP_DIR / f"{safe_title}.md"
    filepath.write_text(content, encoding="utf-8")

    # Save hash and title (title needed for clean-up later)
    saved_hashes[note_id] = {"hash": curr_hash, "title": title}
    exported += 1
    print(f"  ✓  Exported: {title}")

# Save updated state
STATE_FILE.write_text(json.dumps(saved_hashes, indent=2), encoding="utf-8")
print(f"\nDone: {exported} exported, {skipped} unchanged, {removed} removed.")

# ── Rsync to secondary location ───────────────────────────────────────────
if SYNC_DIR is None:
    exit(0)

if SYNC_MOUNT.is_mount():
    SYNC_DIR.mkdir(parents=True, exist_ok=True)
    print("\n📡 Sync destination available, starting rsync...")
    rsync = subprocess.run(
        [
            "rsync",
            "--archive",    # preserve permissions, timestamps etc.
            "--delete",     # remove files deleted locally
            str(BACKUP_DIR) + "/",
            str(SYNC_DIR) + "/"
        ],
        capture_output=True, text=True
    )
    if rsync.returncode == 0:
        print("✅ Rsync completed successfully.")
    else:
        print(f"⚠️  Rsync error: {rsync.stderr}")
else:
    print("\n⚠️  Sync destination not available, rsync skipped. Will retry on next run.")
EOF
