#!/bin/bash

PUSH_ENABLED=false
MR_ENABLED=false
ASSUME_YES=false

# 1. Parse optional flags
while [[ "$1" == --* || "$1" == -* ]]; do
    case "$1" in
        --push) PUSH_ENABLED=true; shift ;;
        --create-mr) MR_ENABLED=true; shift ;;
        -y) ASSUME_YES=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# 2. Argument Check
if [ "$#" -lt 4 ]; then
    echo "Usage: $0 [--push] [--create-mr] [-y] <versions_file> <branch_name> <msg_prefix> <dirs...>"
    exit 1
fi

VERSIONS_FILE=$1
BRANCH_NAME=$3
MSG_PREFIX=$4
shift 3
DEP_PROJECTS=("$@")

# Check if file exists
if [ ! -f "$VERSIONS_FILE" ]; then
    echo "ERROR: Versions file '$VERSIONS_FILE' not found."
    exit 1
fi

ROOT_DIR=$(pwd)
UPDATED_PROJECTS=() 
SKIPPED_PROJECTS=()



for proj in "${DEP_PROJECTS[@]}"; do
    echo "======================================================"
    echo ">>> PROCESSING: $proj"
    echo "======================================================"
    
    if [ ! -d "$proj" ]; then SKIPPED_PROJECTS+=("$proj (No dir)"); continue; fi
    POM_PATH="$proj/pom.xml"
    if [ ! -f "$POM_PATH" ]; then SKIPPED_PROJECTS+=("$proj (No pom.xml)"); continue; fi

    # --- NEW: Filter versions file to see if this project needs any updates ---
    # This reads the file and checks if any 'dep_name' exists in this project's pom
    UPDATES_TO_APPLY=()
    while read -r dep_name version || [ -n "$dep_name" ]; do
        [[ -z "$dep_name" || "$dep_name" == \#* ]] && continue # Skip empty or comments
        if grep -q "<${dep_name}.version>" "$POM_PATH"; then
            UPDATES_TO_APPLY+=("$dep_name:$version")
        fi
    done < "$VERSIONS_FILE"

    if [ ${#UPDATES_TO_APPLY[@]} -eq 0 ]; then
        SKIPPED_PROJECTS+=("$proj (No matching dependencies found in file)")
        continue
    fi

    if ! cd "$proj"; then SKIPPED_PROJECTS+=("$proj (CD failed)"); continue; fi

    # Git Setup
    git reset --hard HEAD > /dev/null
    git clean -fd > /dev/null
    if ! (git checkout main || git checkout master) > /dev/null 2>&1; then
        SKIPPED_PROJECTS+=("$proj (Main/Master not found)"); cd "$ROOT_DIR"; continue
    fi

    git branch -D develop > /dev/null 2>&1
    git fetch origin > /dev/null 2>&1
    git checkout -b develop origin/develop > /dev/null 2>&1 || { SKIPPED_PROJECTS+=("$proj (Develop sync failed)"); cd "$ROOT_DIR"; continue; }
    
    git branch -D "$BRANCH_NAME" > /dev/null 2>&1
    git checkout -b "$BRANCH_NAME" > /dev/null 2>&1

    # Apply all relevant updates from the file
    COMMIT_MSG_DETAILS=""
    for update in "${UPDATES_TO_APPLY[@]}"; do
        d_name="${update%%:*}"
        d_ver="${update#*:}"
        echo "Updating <${d_name}.version> to $d_ver..."
        sed -i "s|<${d_name}.version>.*</${d_name}.version>|<${d_name}.version>${d_ver}</${d_name}.version>|g" "pom.xml"
        COMMIT_MSG_DETAILS+="$d_name to $d_ver, "
    done

    # Commit (clean up trailing comma from message)
    git add "pom.xml"
    if ! git commit -m "${MSG_PREFIX}: update ${COMMIT_MSG_DETAILS%, }"; then
        SKIPPED_PROJECTS+=("$proj (Commit failed)"); cd "$ROOT_DIR"; continue
    fi

    # Push logic
    CURRENT_STATUS="Updated Locally"
    if [ "$PUSH_ENABLED" = true ]; then
        SHOULD_PUSH=false
        if [ "$ASSUME_YES" = true ]; then SHOULD_PUSH=true
        else
            echo "PROPOSED CHANGES FOR: $proj"
            echo "------------------------------------------------------"
            git diff --color=always HEAD~1 HEAD
            echo "------------------------------------------------------"
            read -p "Push this commit to origin and open MR? (y/N): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && SHOULD_PUSH=true
        fi

        if [ "$SHOULD_PUSH" = true ]; then
            PUSH_CMD="git push origin $BRANCH_NAME --force"
            [ "$MR_ENABLED" = true ] && PUSH_CMD="$PUSH_CMD -o merge_request.create -o merge_request.target=develop -o merge_request.remove_source_branch=true"
            eval $PUSH_CMD && CURRENT_STATUS="Pushed to Remote" || CURRENT_STATUS="Push FAILED"
        fi
    fi

    UPDATED_PROJECTS+=("$proj ($CURRENT_STATUS)")
    cd "$ROOT_DIR"
done

# Final Summary (Report logic remains same)
