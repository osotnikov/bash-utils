#!/bin/bash

PUSH_ENABLED=false
MR_ENABLED=false
ASSUME_YES=false
OPEN_IN_FIREFOX=false

# 1. Parse optional flags
while [[ "$1" == --* || "$1" == -* ]]; do
    case "$1" in
        --push) PUSH_ENABLED=true; shift ;;
        --create-mr) MR_ENABLED=true; shift ;;
        --open-mrs) OPEN_IN_FIREFOX=true; shift ;;
        -y) ASSUME_YES=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# 2. Argument Check
if [ "$#" -lt 4 ]; then
    echo "Usage: $0 [--push] [--create-mr] [--open-mrs] [-y] <versions_file> <branch_name> <msg_prefix> <dirs...>"
    exit 1
fi

VERSIONS_FILE=$1
BRANCH_NAME=$2
MSG_PREFIX=$3
shift 3
DEP_PROJECTS=("$@")

if [ ! -f "$VERSIONS_FILE" ]; then
    echo "ERROR: Versions file '$VERSIONS_FILE' not found."
    exit 1
fi

ROOT_DIR=$(pwd)
UPDATED_PROJECTS=() 
SKIPPED_PROJECTS=()
MR_LINKS=() 

for proj in "${DEP_PROJECTS[@]}"; do
    echo "======================================================"
    echo ">>> PROCESSING: $proj"
    echo "======================================================"
    
    if [ ! -d "$proj" ]; then SKIPPED_PROJECTS+=("$proj (No dir)"); continue; fi
    POM_PATH="$proj/pom.xml"
    
    UPDATES_TO_APPLY=()
    while read -r dep_name version || [ -n "$dep_name" ]; do
        [[ -z "$dep_name" || "$dep_name" == \#* ]] && continue 
        if grep -q "<${dep_name}.version>" "$POM_PATH"; then
            UPDATES_TO_APPLY+=("$dep_name:$version")
        fi
    done < "$VERSIONS_FILE"

    if [ ${#UPDATES_TO_APPLY[@]} -eq 0 ]; then
        SKIPPED_PROJECTS+=("$proj (No matching deps)"); continue
    fi

    if ! cd "$proj"; then SKIPPED_PROJECTS+=("$proj (CD failed)"); continue; fi

    # Git Setup
    git reset --hard HEAD > /dev/null
    git clean -fd > /dev/null
    (git checkout main || git checkout master) > /dev/null 2>&1
    git branch -D develop > /dev/null 2>&1
    git fetch origin > /dev/null 2>&1
    git checkout -b develop origin/develop > /dev/null 2>&1 || { SKIPPED_PROJECTS+=("$proj (Sync failed)"); cd "$ROOT_DIR"; continue; }
    git branch -D "$BRANCH_NAME" > /dev/null 2>&1
    git checkout -b "$BRANCH_NAME" > /dev/null 2>&1

    # Modify and Commit
    COMMIT_MSG_DETAILS=""
    for update in "${UPDATES_TO_APPLY[@]}"; do
        d_name="${update%%:*}"
        d_ver="${update#*:}"
        sed -i "s|<${d_name}.version>.*</${d_name}.version>|<${d_name}.version>${d_ver}</${d_name}.version>|g" "pom.xml"
        COMMIT_MSG_DETAILS+="$d_name to $d_ver, "
    done

    git add "pom.xml"
    if ! git commit -m "${MSG_PREFIX}: update ${COMMIT_MSG_DETAILS%, }"; then
        SKIPPED_PROJECTS+=("$proj (Commit failed)"); cd "$ROOT_DIR"; continue
    fi

    # Push and Capture Link
    CURRENT_STATUS="Updated Locally"
    if [ "$PUSH_ENABLED" = true ]; then
        SHOULD_PUSH=false
        [ "$ASSUME_YES" = true ] && SHOULD_PUSH=true || {
            echo "PROPOSED CHANGES FOR: $proj"
            git diff --color=always HEAD~1 HEAD
            read -p "Push this commit? (y/N): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && SHOULD_PUSH=true
        }

        if [ "$SHOULD_PUSH" = true ]; then
            PUSH_CMD="git push origin $BRANCH_NAME --force"
            [ "$MR_ENABLED" = true ] && PUSH_CMD="$PUSH_CMD -o merge_request.create -o merge_request.target=develop -o merge_request.remove_source_branch=true"
            
            PUSH_OUTPUT=$(eval $PUSH_CMD 2>&1)
            if [ $? -eq 0 ]; then
                CURRENT_STATUS="Pushed to Remote"
                URL=$(echo "$PUSH_OUTPUT" | grep -o 'https://[^ ]*/merge_requests/[0-9]*')
                if [ -n "$URL" ]; then
                    MR_LINKS+=("$URL")
                    CURRENT_STATUS="MR Created"
                fi
            else
                CURRENT_STATUS="Push FAILED"
            fi
        fi
    fi

    UPDATED_PROJECTS+=("$proj ($CURRENT_STATUS)")
    cd "$ROOT_DIR"
done

# --- FINAL REPORT ---
echo -e "\n======================================================"
echo "                FINAL EXECUTION REPORT                "
echo "======================================================"
echo "PROJECT STATUS:"
for up in "${UPDATED_PROJECTS[@]}"; do echo " [✓] $up"; done
echo -e "\nSKIPPED PROJECTS:"
for sk in "${SKIPPED_PROJECTS[@]}"; do echo " [✗] $sk"; done

# --- AUTOMATIC BROWSER OPENING ---
if [ "$OPEN_IN_FIREFOX" = true ] && [ ${#MR_LINKS[@]} -gt 0 ]; then
    if command -v firefox > /dev/null; then
        echo -e "\nOpening ${#MR_LINKS[@]} Merge Requests in Firefox..."
        for link in "${MR_LINKS[@]}"; do
            firefox --new-tab "$link" & 
            sleep 0.2 # Slight delay to help browser handle multiple tabs
        done
    else
        echo -e "\n[!] Could not find 'firefox' command in your PATH."
    fi
fi
echo "======================================================"
