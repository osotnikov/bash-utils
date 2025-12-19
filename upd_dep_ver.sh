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
if [ "$#" -lt 5 ]; then
    echo "Usage: $0 [--push] [--create-mr] [-y] <dep_name> <version> <branch> <prefix> <dirs...>"
    exit 1
fi

DEP_NAME=$1
NEW_VERSION=$2
BRANCH_NAME=$3
MSG_PREFIX=$4
shift 4
DEP_PROJECTS=("$@")

ROOT_DIR=$(pwd)
UPDATED_PROJECTS=() 
SKIPPED_PROJECTS=()

for proj in "${DEP_PROJECTS[@]}"; do
    echo "======================================================"
    echo ">>> PROCESSING: $proj"
    echo "======================================================"
    
    if [ ! -d "$proj" ]; then SKIPPED_PROJECTS+=("$proj (No dir)"); continue; fi
    POM_PATH="$proj/pom.xml"
    if [ ! -f "$POM_PATH" ] || ! grep -q "<${DEP_NAME}.version>" "$POM_PATH"; then
        SKIPPED_PROJECTS+=("$proj (Property not found)"); continue
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

    # Modify the pom.xml
    sed -i "s|<${DEP_NAME}.version>.*</${DEP_NAME}.version>|<${DEP_NAME}.version>${NEW_VERSION}</${DEP_NAME}.version>|g" "pom.xml"
    
    # 3. COMMIT ALWAYS (If changes exist)
    git add "pom.xml"
    if ! git commit -m "${MSG_PREFIX}: update ${DEP_NAME} version to ${NEW_VERSION}"; then
        SKIPPED_PROJECTS+=("$proj (Commit failed - no changes)"); cd "$ROOT_DIR"; continue
    fi

    # 4. CONDITIONAL PUSH LOGIC
    CURRENT_STATUS="Updated Locally"
    if [ "$PUSH_ENABLED" = true ]; then
        SHOULD_PUSH=false
        
        if [ "$ASSUME_YES" = true ]; then
            SHOULD_PUSH=true
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
            
            if eval $PUSH_CMD; then
                CURRENT_STATUS="Pushed to Remote"
            else
                CURRENT_STATUS="Commit saved, but Push FAILED"
            fi
        else
            echo "Push skipped. Commit remains on local branch '$BRANCH_NAME'."
            CURRENT_STATUS="Updated Locally (Push declined)"
        fi
    fi

    UPDATED_PROJECTS+=("$proj ($CURRENT_STATUS)")
    cd "$ROOT_DIR"
done

# 5. Final Summary
echo -e "\n======================================================"
echo "                FINAL EXECUTION REPORT                "
echo "======================================================"
echo "SUCCESSFUL PROJECTS:"
for up in "${UPDATED_PROJECTS[@]}"; do echo " [✓] $up"; done
echo -e "\nSKIPPED/FAILED PROJECTS:"
for sk in "${SKIPPED_PROJECTS[@]}"; do echo " [✗] $sk"; done
echo "======================================================"
