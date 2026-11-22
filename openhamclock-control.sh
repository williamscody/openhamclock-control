#!/bin/bash
#
# openhamclock-control.sh — desktop control panel and safe updater for OpenHamClock
# https://github.com/williamscody/openhamclock-control
#
# Released under the MIT License (see LICENSE).

SERVICE="openhamclock"
APP_DIR="$HOME/openhamclock"
BACKUP_ROOT="$HOME/OpenHamClock-Backups"
REPO_URL="https://github.com/accius/openhamclock.git"
RELEASE_API="https://api.github.com/repos/accius/openhamclock/releases/latest"

# Hands-off mode.
#   false = ask before updating, and show the .env merge for review before applying it
#   true  = no prompts: update and apply the merged .env automatically
# Running "openhamclock-control.sh --auto" forces true for that run (no menu, no
# windows) and appends the output to $BACKUP_ROOT/auto-update.log, e.g. for cron.
AUTO_MODE=false

# --------------------------------------------------
# Helpers
# --------------------------------------------------

# Show an info box, unless running hands-off (then the log line is enough)
notify() {
    if [[ "$AUTO_MODE" != true ]]; then
        zenity --info --title="OpenHamClock" --text="$1" || true
    fi
}

# --------------------------------------------------
# .env merge
# --------------------------------------------------
#
# merge_env USER_ENV OLD_EXAMPLE NEW_EXAMPLE MERGED_OUT REPORT_OUT
#
# Builds a new .env from the release's .env.example, carrying your settings over:
#   - The new .env.example is the template (so new settings, comments and layout arrive).
#   - Every KEY=value you have replaces the template's line for that key.
#   - If you set a key that the template only shows commented out ("# KEY=..."),
#     your active line takes that commented line's place.
#   - If you commented out a key that the template has active, it stays commented out.
#   - Keys you have that the template no longer mentions are kept in a block at the end.
# The report lists key names only (plus public template defaults, never your values).
merge_env() {
    awk -v userf="$1" -v oldf="$2" -v newf="$3" -v report="$5" '
    # Active "KEY=value" (optionally "export KEY=value") -> KEY, else ""
    function keyof(line,    k) {
        if (line !~ /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) return ""
        k = line
        sub(/^[ \t]*(export[ \t]+)?/, "", k)
        sub(/[ \t]*=.*/, "", k)
        return k
    }
    # Commented-out "# KEY=value" (upper-case keys only, so prose is ignored) -> KEY
    function ckeyof(line,    k) {
        if (line !~ /^[ \t]*#[ \t]*(export[ \t]+)?[A-Z_][A-Z0-9_]*=/) return ""
        k = line
        sub(/^[ \t]*#[ \t]*(export[ \t]+)?/, "", k)
        sub(/=.*/, "", k)
        return k
    }
    function valof(line,    v) {
        v = line
        sub(/^[^=]*=/, "", v)
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        return v
    }

    { sub(/\r$/, "") }

    FILENAME == userf {
        k = keyof($0)
        if (k != "") {
            if (k in uline) { if (!(k in dup)) { dup[k] = 1; dups = dups "  " k "\n" } }
            else uorder[++nu] = k
            uline[k] = $0                    # last one wins, as dotenv does
        } else {
            k = ckeyof($0)
            if (k != "" && !(k in ucomment)) ucomment[k] = $0
        }
        next
    }

    FILENAME == oldf {
        k = keyof($0)
        if (k != "") { olddef[k] = valof($0); oldseen[k] = 1; next }
        k = ckeyof($0)
        if (k != "") oldseen[k] = 1
        next
    }

    FILENAME == newf {
        k = keyof($0)
        if (k != "") {
            if (k in done) next              # template repeats a key: emit it once
            done[k] = 1
            if (k in uline) {
                print uline[k]
                nv = valof($0)
                if ((k in olddef) && olddef[k] != nv && valof(uline[k]) == olddef[k])
                    defchg = defchg "  " k ": old default \"" olddef[k] "\", new default \"" nv "\"\n"
            } else if (k in ucomment) {
                print ucomment[k]
                off = off "  " k "\n"
            } else {
                print
                added = added "  " k "=" valof($0) "\n"
            }
            next
        }
        k = ckeyof($0)
        if (k != "") {
            if ((k in uline) && !(k in done)) { print uline[k]; done[k] = 1; next }
            if (!(k in oldseen) && !(k in uline) && !(k in optseen)) {
                optseen[k] = 1
                opt = opt "  " k "\n"
            }
        }
        print
        next
    }

    END {
        first = 1
        for (i = 1; i <= nu; i++) {
            k = uorder[i]
            if (k in done) continue
            if (first) {
                print ""
                print "# ==========================================="
                print "# Carried over from your previous .env"
                print "# (not in the current .env.example: custom, renamed or retired settings)"
                print "# ==========================================="
                first = 0
            }
            print uline[k]
            extra = extra "  " k "\n"
        }

        printf "" > report
        if (added != "")  printf "New settings added with their default values:\n%s\n", added > report
        if (opt != "")    printf "New optional settings available (commented out in .env):\n%s\n", opt > report
        if (defchg != "") printf "Upstream changed these defaults; you still have the old default (kept):\n%s\n", defchg > report
        if (off != "")    printf "Kept commented out, as in your previous .env:\n%s\n", off > report
        if (extra != "")  printf "Not in the new .env.example; kept at the end of .env:\n%s\n", extra > report
        if (dups != "")   printf "Set more than once in your previous .env; the last value was kept:\n%s\n", dups > report
    }
    ' "$1" "$2" "$3" > "$4"
}

# Merge the current .env into the newly checked-out release's .env.example.
# Called by update_worker (uses its APP_DIR / BACKUP_DIR / CURRENT_COMMIT).
update_env() {
    local env_file="$APP_DIR/.env"
    local new_example="$APP_DIR/.env.example"
    local old_example="$BACKUP_DIR/env.example.previous"
    local merged="$BACKUP_DIR/env.merged"
    local report="$BACKUP_DIR/env-merge-report.txt"
    local review="$BACKUP_DIR/env-merge-review.txt"

    echo "Merging your .env settings into the new release..."

    if [[ ! -f "$new_example" ]]; then
        echo "  This release has no .env.example; your .env was left unchanged."
        return 0
    fi

    # The previous release's template, used to spot new and changed defaults
    git -C "$APP_DIR" show "$CURRENT_COMMIT:.env.example" > "$old_example" 2>/dev/null \
        || : > "$old_example"

    merge_env "$env_file" "$old_example" "$new_example" "$merged" "$report"
    chmod 600 "$old_example" "$merged" "$report"

    if cmp -s "$env_file" "$merged"; then
        echo "  Your .env already matches the new release; nothing to change."
        return 0
    fi

    if [[ -s "$report" ]]; then
        sed 's/^/  /' "$report"
    else
        echo "  Only comments and layout changed."
    fi

    if [[ "$AUTO_MODE" != true ]]; then
        {
            cat "$report"
            echo "Line-by-line changes (- current .env, + merged .env):"
            echo
            diff -u --label "current .env" --label "merged .env" "$env_file" "$merged" || true
        } > "$review"
        chmod 600 "$review"

        if ! zenity --text-info --title="OpenHamClock: review .env changes" \
                --filename="$review" --width=780 --height=560 \
                --ok-label="Apply merged .env" --cancel-label="Keep my current .env"; then
            rm -f "$review"
            echo "  You kept your current .env. The merged version is saved at:"
            echo "  $merged"
            return 0
        fi
        rm -f "$review"
    fi

    # Write in place so .env keeps its owner and permissions
    cat "$merged" > "$env_file"
    echo "  .env updated. Your previous .env is in $BACKUP_DIR/user-data.tar.gz"
}

# --------------------------------------------------
# Update engine
# --------------------------------------------------

update_worker() (
    set -Eeuo pipefail

    echo "Checking OpenHamClock releases... ($(date '+%Y-%m-%d %H:%M:%S'))"

    cd "$APP_DIR"

    # Verify installation and repository
    if [[ "$(git remote get-url origin)" != "$REPO_URL" ]]; then
        echo "ERROR: Unexpected Git repository."
        exit 1
    fi

    # Only changes to files git tracks block an update. Untracked files (stray
    # backups, helper scripts) don't interfere with switching releases.
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "ERROR: Git working directory has local changes to tracked files:"
        git status --porcelain --untracked-files=no
        echo "Please review these changes before updating."
        exit 1
    fi

    CURRENT_COMMIT=$(git rev-parse HEAD)
    CURRENT_VERSION=$(git describe --tags --always)
    PREVIOUS_BRANCH=$(git symbolic-ref --quiet --short HEAD || true)
    OLD_LOCK=$(sha256sum package-lock.json | cut -d' ' -f1)

    echo "Installed version: $CURRENT_VERSION"

    # Retrieve latest official GitHub release
    LATEST=$(curl -fsSL --connect-timeout 15 "$RELEASE_API" |
        python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")

    if [[ ! "$LATEST" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
        echo "ERROR: Unexpected release tag: $LATEST"
        exit 1
    fi

    echo "Latest official release: $LATEST"

    # Fetch official release tags
    git fetch --tags origin

    TARGET_COMMIT=$(git rev-parse --verify "refs/tags/${LATEST}^{commit}")

    if [[ "$TARGET_COMMIT" == "$CURRENT_COMMIT" ]]; then
        notify "You are already running the latest release: $LATEST"
        echo "Already up to date."
        exit 0
    fi

    # Avoid downgrading a checkout that already contains the release
    if git merge-base --is-ancestor "$TARGET_COMMIT" "$CURRENT_COMMIT"; then
        notify "Your current checkout already contains release $LATEST.\n\nNo update is necessary."
        echo "Current checkout already contains this release."
        exit 0
    fi

    if [[ "$AUTO_MODE" != true ]]; then
        if ! zenity --question --title="OpenHamClock Update" \
            --width=420 \
            --text="Installed: $CURRENT_VERSION\nAvailable: $LATEST\n\nProceed with the update?\n\nA backup will be created first."; then
            echo "Update cancelled."
            exit 0
        fi
    fi

    # Create protected backup directory
    STAMP=$(date +%Y%m%d-%H%M%S)
    BACKUP_DIR="$BACKUP_ROOT/$STAMP"

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"

    echo "Creating backup: $BACKUP_DIR"

    # Save repository history
    git bundle create "$BACKUP_DIR/repository.bundle" --all

    # Save configuration and application data (data/ only if it exists,
    # otherwise tar fails and the update would abort)
    BACKUP_ITEMS=(.env)
    if [[ -d "$APP_DIR/data" ]]; then
        BACKUP_ITEMS+=(data)
    fi
    tar -czf "$BACKUP_DIR/user-data.tar.gz" \
        -C "$APP_DIR" "${BACKUP_ITEMS[@]}"

    # Save recovery information
    {
        echo "Previous commit: $CURRENT_COMMIT"
        echo "Previous branch: ${PREVIOUS_BRANCH:-DETACHED}"
        echo "Previous version: $CURRENT_VERSION"
        echo "Target release: $LATEST"
    } > "$BACKUP_DIR/restore-info.txt"

    chmod 600 "$BACKUP_DIR"/*

    # Rollback procedure (also restores the original .env from the backup)
    rollback() {
        echo "UPDATE FAILED. Attempting rollback..."

        sudo systemctl stop "$SERVICE" || true

        if [[ -n "$PREVIOUS_BRANCH" ]]; then
            git switch "$PREVIOUS_BRANCH" || \
                git checkout --detach "$CURRENT_COMMIT"
        else
            git checkout --detach "$CURRENT_COMMIT"
        fi

        tar -xzf "$BACKUP_DIR/user-data.tar.gz" -C "$APP_DIR"

        npm ci

        sudo systemctl restart "$SERVICE"

        echo "Rollback attempted. Check service status and logs."
    }

    # Stop application
    echo "Stopping OpenHamClock..."
    sudo systemctl stop "$SERVICE"

    # Switch to official release
    echo "Installing $LATEST..."
    if ! git checkout --detach "$LATEST"; then
        rollback
        exit 1
    fi

    # Carry your .env settings into the new release's .env template
    if ! update_env; then
        rollback
        exit 1
    fi

    # Reinstall dependencies only if necessary
    NEW_LOCK=$(sha256sum package-lock.json | cut -d' ' -f1)

    if [[ "$OLD_LOCK" != "$NEW_LOCK" ]]; then
        echo "Dependencies changed. Running npm ci..."
        if ! npm ci; then
            rollback
            exit 1
        fi
    else
        echo "Dependencies unchanged. Skipping npm ci."
    fi

    # Restart (npm start automatically runs the build)
    echo "Restarting OpenHamClock..."
    if ! sudo systemctl restart "$SERVICE"; then
        rollback
        exit 1
    fi

    # Allow startup/build time
    echo "Waiting for application startup..."
    sleep 15

    if ! systemctl is-active --quiet "$SERVICE"; then
        echo "ERROR: Service failed to start."
        rollback
        exit 1
    fi

    INSTALLED=$(git describe --tags --always)

    echo "----------------------------------"
    echo "UPDATE SUCCESSFUL"
    echo "Installed version: $INSTALLED"
    echo "Backup: $BACKUP_DIR"
    echo "----------------------------------"
)

# --------------------------------------------------
# Display update results
# --------------------------------------------------

check_updates() {
    LOG_FILE=$(mktemp /tmp/openhamclock-update.XXXXXX)

    if update_worker > "$LOG_FILE" 2>&1; then
        zenity --text-info \
            --title="OpenHamClock Update Results" \
            --filename="$LOG_FILE" \
            --width=650 --height=450
    else
        zenity --error \
            --title="OpenHamClock Update Error" \
            --text="The update did not complete successfully.\n\nReview the details in the next window."

        zenity --text-info \
            --title="Update Details" \
            --filename="$LOG_FILE" \
            --width=700 --height=500
    fi

    rm -f "$LOG_FILE"
}

# --------------------------------------------------
# Unattended mode: openhamclock-control.sh --auto
# --------------------------------------------------

if [[ "${1:-}" == "--auto" ]]; then
    AUTO_MODE=true
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
    update_worker >> "$BACKUP_ROOT/auto-update.log" 2>&1
    STATUS=$?
    echo "" >> "$BACKUP_ROOT/auto-update.log"
    exit $STATUS
fi

# --------------------------------------------------
# Existing control panel
# --------------------------------------------------

while true; do

    STATUS=$(systemctl is-active "$SERVICE")
    ENABLED=$(systemctl is-enabled "$SERVICE" 2>/dev/null)

    if [ "$ENABLED" != "enabled" ]; then
        ENABLED="disabled"
    fi

    CHOICE=$(zenity --list \
        --title="OpenHamClock Control (Status: $STATUS | Autostart: $ENABLED)" \
        --height=420 \
        --width=450 \
        --column="Action" \
        "View Live Logs" \
        "Start Service" \
        "Restart Service" \
        "Stop Service" \
        "Enable Autostart" \
        "Disable Autostart" \
        "Check for Updates" \
        "Exit")

    if [ -z "$CHOICE" ]; then
        exit 0
    fi

    case "$CHOICE" in

        "View Live Logs")
            gnome-terminal -- bash -c \
                "echo 'Streaming logs for $SERVICE...'; journalctl -u $SERVICE -f; exec bash"
            ;;

        "Start Service")
            sudo systemctl start "$SERVICE"
            zenity --info --text="OpenHamClock started."
            ;;

        "Restart Service")
            sudo systemctl restart "$SERVICE"
            zenity --info --text="OpenHamClock restarted."
            ;;

        "Stop Service")
            if zenity --question --text="Are you sure you want to stop OpenHamClock?"; then
                sudo systemctl stop "$SERVICE"
                zenity --info --text="OpenHamClock stopped."
            fi
            ;;

        "Enable Autostart")
            sudo systemctl enable "$SERVICE"
            zenity --info --text="Autostart ENABLED."
            ;;

        "Disable Autostart")
            if zenity --question --text="Disable autostart for OpenHamClock?"; then
                sudo systemctl disable "$SERVICE"
                zenity --info --text="Autostart DISABLED."
            fi
            ;;

        "Check for Updates")
            check_updates
            ;;

        "Exit")
            exit 0
            ;;

    esac

done
