#!/bin/bash

# --- Flags & Arguments Parsing ---
PUSH_ENABLED=false
MR_ENABLED=false
OPEN_IN_FIREFOX=false
ASSUME_YES=false

while [[ "$1" == --* || "$1" == -* ]]; do
    case "$1" in
        --push) PUSH_ENABLED=true; shift ;;
        --create-mr) MR_ENABLED=true; shift ;;
        --open-mrs) OPEN_IN_FIREFOX=true; shift ;;
        -y) ASSUME_YES=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$#" -lt 5 ]; then
    echo "Usage: $0 [flags] <versions_file> <ignore_file> <branch_name> <msg_prefix> <dirs...>"
    exit 1
fi

VERSIONS_FILE="$(realpath "$1")"
IGNORE_FILE="$(realpath "$2")"
BRANCH_NAME=$3
MSG_PREFIX=$4
shift 4
DEP_PROJECTS=("$@")

ROOT_DIR=$(pwd)
UPDATED_PROJECTS=() 
SKIPPED_PROJECTS=()
MR_LINKS=() 

# --- Load Ignore List ---
declare -A IGNORE_LIST
if [ -f "$IGNORE_FILE" ]; then
    while read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        IGNORE_LIST["$line"]=1
    done < "$IGNORE_FILE"
fi

for proj in "${DEP_PROJECTS[@]}"; do
    # --- THE FIX: Strip trailing slash ---
    proj="${proj%/}"
    
    echo "======================================================"
    echo ">>> PROCESSING: $proj"
    echo "======================================================"
    
    if [[ ${IGNORE_LIST["$proj"]} ]]; then
        SKIPPED_PROJECTS+=("$proj (Ignored via file)")
        echo "[!] Skipping: $proj is in the ignore file."
        continue
    fi

    if [ ! -d "$proj" ]; then SKIPPED_PROJECTS+=("$proj (No dir)"); continue; fi
    if ! cd "$proj"; then SKIPPED_PROJECTS+=("$proj (CD failed)"); continue; fi

    # Sync and Clean
    git reset --hard HEAD > /dev/null
    git clean -fd > /dev/null
    (git checkout main || git checkout master) > /dev/null 2>&1
    git branch -D develop > /dev/null 2>&1
    git fetch origin > /dev/null 2>&1
    if ! git checkout -b develop origin/develop > /dev/null 2>&1; then
        SKIPPED_PROJECTS+=("$proj (Develop sync failed)"); cd "$ROOT_DIR"; continue
    fi

    # Project Version (Parent-aware)
    PROJ_VERSION=$(perl -0777 -ne 's/<parent>.*?<\/parent>//s; print $1 if /<version>\s*(.*?)\s*<\/version>/s' pom.xml | head -n 1 | xargs)
    echo "[Info] Target Project Version: $PROJ_VERSION"

    # Identify updates
    UPDATES_TO_APPLY=()
    COMMIT_MSG_DETAILS=""
    while read -r dep_name new_version || [ -n "$dep_name" ]; do
        [[ -z "$dep_name" || "$dep_name" == \#* ]] && continue 
        if grep -q "<${dep_name}.version>" pom.xml; then
            UPDATES_TO_APPLY+=("$dep_name:$new_version")
            COMMIT_MSG_DETAILS+="update $dep_name to $new_version, "
        fi
    done < "$VERSIONS_FILE"

    if [ ${#UPDATES_TO_APPLY[@]} -eq 0 ]; then
        SKIPPED_PROJECTS+=("$proj (v$PROJ_VERSION - No updates needed)")
        cd "$ROOT_DIR"; continue
    fi

    # Branch and Update
    git branch -D "$BRANCH_NAME" > /dev/null 2>&1
    git checkout -b "$BRANCH_NAME" > /dev/null 2>&1

    for update in "${UPDATES_TO_APPLY[@]}"; do
        d_name="${update%%:*}"
        d_ver="${update#*:}"
        sed -i "s|<${d_name}.version>.*</${d_name}.version>|<${d_name}.version>${d_ver}</${d_name}.version>|g" "pom.xml"
    done

    # --- Multi-line Commit and Immediate Diff ---
    git add "pom.xml"
    FULL_MSG="${MSG_PREFIX}"$'\n\n'"${COMMIT_MSG_DETAILS%, }"
    
    if git commit -m "$FULL_MSG" > /dev/null; then
        echo "------------------------------------------------------"
        echo "LOCAL COMMIT CREATED FOR $proj (v$PROJ_VERSION)"
        git diff -U3 --color=always HEAD~1 HEAD
        echo "------------------------------------------------------"
    else
        SKIPPED_PROJECTS+=("$proj (v$PROJ_VERSION - Commit failed)")
        cd "$ROOT_DIR"; continue
    fi

    # --- Push Logic ---
    STATUS="Local-Only"
    if [ "$PUSH_ENABLED" = true ]; then
        SHOULD_PUSH=false
        if [ "$ASSUME_YES" = true ]; then 
            SHOULD_PUSH=true
        else
            read -p "Push this commit and create MR for branch $BRANCH_NAME? (y/N): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && SHOULD_PUSH=true
        fi

        if [ "$SHOULD_PUSH" = true ]; then
            PUSH_CMD="git push origin $BRANCH_NAME"
            [ "$MR_ENABLED" = true ] && PUSH_CMD="$PUSH_CMD -o merge_request.create -o merge_request.target=develop -o merge_request.remove_source_branch=true"
            
            PUSH_OUTPUT=$(eval $PUSH_CMD 2>&1)
            if [ $? -eq 0 ]; then
                STATUS="Pushed"
                URL=$(echo "$PUSH_OUTPUT" | grep -o 'https://[^ ]*/merge_requests/[0-9]*')
                
                if [ -n "$URL" ]; then
                    STATUS="MR Created"
                    # Add to list for the final report
                    MR_LINKS+=("$URL")
                    
                    if [ "$OPEN_IN_FIREFOX" = true ] && [ "$ASSUME_YES" = true ]; then
                        echo "[Browser] Opening MR: $URL"
                        firefox --new-tab "$URL" > /dev/null 2>&1 &
                    fi
                fi
            else
                STATUS="Push FAILED"
                echo "$PUSH_OUTPUT"
            fi
        fi
    fi

    UPDATED_PROJECTS+=("$proj (v$PROJ_VERSION) | $STATUS")
    cd "$ROOT_DIR"
done

# --- Final Report ---
echo -e "\n======================================================"
echo "                FINAL EXECUTION REPORT                "
echo "======================================================"
echo "UPDATED PROJECTS:"
for up in "${UPDATED_PROJECTS[@]}"; do echo " [✓] $up"; done

echo -e "\nSKIPPED PROJECTS:"
for sk in "${SKIPPED_PROJECTS[@]}"; do echo " [✗] $sk"; done

# --- ADDED: MR Link Report ---
if [ ${#MR_LINKS[@]} -gt 0 ]; then
    echo -e "\nMERGE REQUEST LINKS:"
    for link in "${MR_LINKS[@]}"; do echo " [link] $link"; done
fi

# Final Browser Opening (only if not already opened via -y)
if [ "$ASSUME_YES" = false ] && [ "$OPEN_IN_FIREFOX" = true ] && [ ${#MR_LINKS[@]} -gt 0 ]; then
    echo -e "\nOpening ${#MR_LINKS[@]} MRs in Firefox..."
    for link in "${MR_LINKS[@]}"; do
        firefox --new-tab "$link" > /dev/null 2>&1 &
        sleep 0.2
    done
fi
echo "======================================================"
