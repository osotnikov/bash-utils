#!/bin/bash

PUSH_ENABLED=false
MR_ENABLED=false

# 1. Parse optional flags
while [[ "$1" == --* ]]; do
    case "$1" in
        --push)
            PUSH_ENABLED=true
            shift
            ;;
        --create-mr)
            MR_ENABLED=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# 2. Argument Check (5 required positional arguments)
if [ "$#" -lt 5 ]; then
    echo "Usage: $0 [--push] [--create-mr] <dependency_name> <new_version> <branch_name> <msg_prefix> <project_dir1> [project_dir2 ...]"
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
    echo ">>> SCANNING PROJECT: $proj"
    echo "======================================================"
    
    # Validation
    if [ ! -d "$proj" ]; then
        SKIPPED_PROJECTS+=("$proj (Directory not found)")
        continue
    fi

    POM_PATH="$proj/pom.xml"
    if [ ! -f "$POM_PATH" ]; then
        SKIPPED_PROJECTS+=("$proj (No pom.xml)")
        continue
    fi

    if ! grep -q "<${DEP_NAME}.version>" "$POM_PATH"; then
        SKIPPED_PROJECTS+=("$proj (Dependency property not found)")
        continue
    fi

    if ! cd "$proj"; then
        SKIPPED_PROJECTS+=("$proj (Could not enter directory)")
        continue
    fi

    # Git Preparation
    echo "Cleaning and resetting..."
    git reset --hard HEAD || { SKIPPED_PROJECTS+=("$proj (Reset failed)"); cd "$ROOT_DIR"; continue; }
    git clean -fd

    echo "Syncing with develop..."
    if ! (git checkout main || git checkout master); then
        SKIPPED_PROJECTS+=("$proj (Main/Master not found)")
        cd "$ROOT_DIR"; continue
    fi

    git branch -D develop 
    git fetch origin || { SKIPPED_PROJECTS+=("$proj (Fetch failed)"); cd "$ROOT_DIR"; continue; }
    
    if ! git checkout -b develop origin/develop; then
        SKIPPED_PROJECTS+=("$proj (Setup develop failed)")
        cd "$ROOT_DIR"; continue
    fi

    # New Branch creation
    git branch -D "$BRANCH_NAME"
    if ! git checkout -b "$BRANCH_NAME"; then
        SKIPPED_PROJECTS+=("$proj (Branch create failed)")
        cd "$ROOT_DIR"; continue
    fi

    # Modify pom.xml
    sed -i "s|<${DEP_NAME}.version>.*</${DEP_NAME}.version>|<${DEP_NAME}.version>${NEW_VERSION}</${DEP_NAME}.version>|g" "pom.xml"
    
    # Commit
    git add "pom.xml"
    if ! git commit -m "${MSG_PREFIX}: update ${DEP_NAME} version to ${NEW_VERSION}"; then
        SKIPPED_PROJECTS+=("$proj (Commit failed - no changes)")
        cd "$ROOT_DIR"; continue
    fi
    
    # Push Logic
    if [ "$PUSH_ENABLED" = true ]; then
        PUSH_CMD="git push origin $BRANCH_NAME --force"
        
        # Add GitLab MR options only if requested
        if [ "$MR_ENABLED" = true ]; then
            echo "Pushing and requesting Merge Request..."
            PUSH_CMD="$PUSH_CMD -o merge_request.create -o merge_request.target=develop -o merge_request.remove_source_branch=true"
        else
            echo "Pushing to remote (no MR)..."
        fi

        if ! eval $PUSH_CMD; then
            SKIPPED_PROJECTS+=("$proj (Push failed)")
            cd "$ROOT_DIR"; continue
        fi
    else
        echo "Local-only mode: Skipping push."
    fi

    UPDATED_PROJECTS+=("$proj")
    cd "$ROOT_DIR"
done

# Summary Report
echo ""
echo "======================================================"
echo "                FINAL EXECUTION REPORT                "
echo "======================================================"
echo "UPDATED PROJECTS (${#UPDATED_PROJECTS[@]}):"
for updated in "${UPDATED_PROJECTS[@]}"; do echo " [✓] $updated"; done
echo ""
echo "SKIPPED PROJECTS (${#SKIPPED_PROJECTS[@]}):"
for skipped in "${SKIPPED_PROJECTS[@]}"; do echo " [✗] $skipped"; done
echo "======================================================"
