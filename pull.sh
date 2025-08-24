#!/bin/bash

# pull-conf.sh - pull configuration files from various sources
#
# DESCRIPTION:
#   This script supports multiple methods to pull configuration files.
#   Currently supports: git repositories, HTTP/HTTPS downloads
#
# USAGE:
#   pull-conf.sh git [options] <repo_url> <src_path> <dest_path>
#   pull-conf.sh wget [options] <url> <dest_path>
#
# OPTIONS:
#   --force     Overwrite existing destination file
#   --backup    Create backup with timestamp before overwriting
#
# GIT AUTHENTICATION METHODS:
#
# For SSH URLs (git@github.com:user/repo.git):
# 1. SSH Key Authentication:
#    - Generate: ssh-keygen -t rsa -b 4096 -C "your_email@example.com"
#    - Add public key (~/.ssh/id_rsa.pub) to GitHub/GitLab
#    - Add to known_hosts: ssh-keyscan github.com >> ~/.ssh/known_hosts
#    - If using non-default key location, set before running this script:
#      export GIT_SSH_COMMAND="ssh -i /path/to/your/private/key"
#
# For HTTPS URLs (https://github.com/user/repo.git):
# 1. Personal Access Token in URL (multiple formats supported):
#    https://username:ghp_xxxxxxxxxxxx@github.com/user/repo.git
#    https://ghp_xxxxxxxxxxxx@github.com/user/repo.git
#
# 2. When prompted for credentials:
#    Username: your_username (or the token itself)
#    Password: ghp_xxxxxxxxxxxx (your personal access token)
#
# 3. Git Credential Helper:
#    git config --global credential.helper store
#    echo "https://username:ghp_xxxxxxxxxxxx@github.com" >> ~/.git-credentials
#    Then use: https://github.com/user/repo.git
#
# 4. Other credential helpers:
#    git config --global credential.helper cache    # memory cache
#    git config --global credential.helper manager  # system manager
#
# SUDO ENVIRONMENT:
#   When running with sudo, the script automatically uses the original 
#   user's SSH key (~/.ssh/id_rsa) instead of root's key, but only if
#   GIT_SSH_COMMAND is not already set. External GIT_SSH_COMMAND settings
#   take precedence over the script's default.
#
# EXAMPLES:
#   pull-conf.sh git git@github.com:user/configs.git server.conf /etc/liteflow.conf
#   pull-conf.sh git --backup https://github.com/user/configs.git client.conf ./liteflow.conf
#   pull-conf.sh wget https://example.com/liteflow.conf /etc/liteflow.conf
#   pull-conf.sh wget --backup https://configs.example.com/server.json ./liteflow.conf

set +e

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:${PATH}

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PACKAGE_DIR=$(dirname "$SCRIPT_DIR")
PACKAGE_KEY=$(echo "$PACKAGE_DIR" | sed 's|/|_|g')

# Detect original user if running under sudo
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)

# Detect system temporary directory
TEMP_DIR="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"

log() {
    if [ "$1" = "-n" ]; then
        shift
        printf "[%s] %s" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    elif [ "$1" = "-r" ]; then
        shift
        printf "%s\n" "$*"
    else
        printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    fi
}

check_required_commands() {
    local subcommand="$1"
    local missing_commands=()
    
    case "$subcommand" in
        git)
            if ! command -v git >/dev/null; then
                missing_commands+=("git")
            fi
            ;;
        wget)
            if ! command -v wget >/dev/null && ! command -v curl >/dev/null; then
                missing_commands+=("wget or curl")
            fi
            ;;
    esac
    
    if [ ${#missing_commands[@]} -gt 0 ]; then
        log "Error: Missing required command(s): ${missing_commands[*]}"
        log "Please install the missing command(s) before running this script."
        return 1
    fi
    
    return 0
}

pull_wget() {
    local force=0
    local backup=0
    local url=""
    local dest_path=""
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --force)
                force=1
                shift
                ;;
            --backup)
                backup=1
                shift
                ;;
            --*)
                log "Error: Unknown option $1"
                usage_wget
                return 1
                ;;
            *)
                if [ -z "$url" ]; then
                    url="$1"
                elif [ -z "$dest_path" ]; then
                    dest_path="$1"
                else
                    log "Error: Too many arguments"
                    usage_wget
                    return 1
                fi
                shift
                ;;
        esac
    done
    
    # Validate required arguments
    if [ -z "$url" ] || [ -z "$dest_path" ]; then
        log "Error: Missing required arguments"
        usage_wget
        return 1
    fi
    
    # Check if destination exists and handle backup/force
    if [ -f "$dest_path" ]; then
        if [ $backup -eq 1 ]; then
            local backup_file="$dest_path.backup.$(date '+%Y-%m-%d_%H-%M-%S-%6N')"
            log "Creating backup: $backup_file"
            cp "$dest_path" "$backup_file" || {
                log "Error: Failed to create backup"
                return 1
            }
        elif [ $force -eq 0 ]; then
            log "Error: Destination file exists. Use --force to overwrite or --backup to create backup."
            return 1
        fi
    fi
    
    # Check optional tools
    if ! command -v cmp >/dev/null; then
        log "Warning: 'cmp' is not installed. File comparison may not work."
        NO_CMP=1
    else
        NO_CMP=0
    fi
    
    # Create destination directory if needed
    local dest_dir=$(dirname "$dest_path")
    mkdir -p "$dest_dir" || {
        log "Error: Failed to create destination directory"
        return 1
    }
    
    # Set up temporary file for download
    local temp_file="$TEMP_DIR/liteflow_wget.$PACKAGE_KEY.$(date '+%Y-%m-%d_%H-%M-%S-%6N')"
    
    # Download file using wget or curl
    log "Downloading configuration from: $url"
    if command -v wget >/dev/null; then
        wget -q -O "$temp_file" "$url" || {
            log "Error: Failed to download file using wget"
            rm -f "$temp_file"
            return 1
        }
    elif command -v curl >/dev/null; then
        curl -s -o "$temp_file" "$url" || {
            log "Error: Failed to download file using curl"
            rm -f "$temp_file"
            return 1
        }
    else
        log "Error: Neither wget nor curl is available"
        return 1
    fi
    
    # Check if download was successful and file exists
    if [ ! -f "$temp_file" ] || [ ! -s "$temp_file" ]; then
        log "Error: Downloaded file is empty or does not exist"
        rm -f "$temp_file"
        return 1
    fi
    
    
    # Compare and copy file
    if [ "$NO_CMP" -eq 0 ] && [ -f "$dest_path" ]; then
        if ! cmp -s "$temp_file" "$dest_path"; then
            log "Updating $dest_path with new version from URL"
            cp "$temp_file" "$dest_path" || {
                log "Error: Failed to copy file"
                rm -f "$temp_file"
                return 1
            }
        else
            log "No changes detected in config file"
        fi
    else
        if [ "$NO_CMP" -eq 1 ] && [ -f "$dest_path" ]; then
            log "cmp not available, overwriting $dest_path without comparison"
        else
            log "Creating $dest_path from URL"
        fi
        
        cp "$temp_file" "$dest_path" || {
            log "Error: Failed to copy file"
            rm -f "$temp_file"
            return 1
        }
    fi
    
    # Clean up temporary file
    rm -f "$temp_file"
    
    log "Successfully pulled configuration from URL"
    return 0
}

pull_git() {
    local force=0
    local backup=0
    local repo_url=""
    local src_path=""
    local dest_path=""
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --force)
                force=1
                shift
                ;;
            --backup)
                backup=1
                shift
                ;;
            --*)
                log "Error: Unknown option $1"
                usage_git
                return 1
                ;;
            *)
                if [ -z "$repo_url" ]; then
                    repo_url="$1"
                elif [ -z "$src_path" ]; then
                    src_path="$1"
                elif [ -z "$dest_path" ]; then
                    dest_path="$1"
                else
                    log "Error: Too many arguments"
                    usage_git
                    return 1
                fi
                shift
                ;;
        esac
    done
    
    # Validate required arguments
    if [ -z "$repo_url" ] || [ -z "$src_path" ] || [ -z "$dest_path" ]; then
        log "Error: Missing required arguments"
        usage_git
        return 1
    fi
    
    # Check if destination exists and handle backup/force
    if [ -f "$dest_path" ]; then
        if [ $backup -eq 1 ]; then
            local backup_file="$dest_path.backup.$(date '+%Y-%m-%d_%H-%M-%S-%6N')"
            log "Creating backup: $backup_file"
            cp "$dest_path" "$backup_file" || {
                log "Error: Failed to create backup"
                return 1
            }
        elif [ $force -eq 0 ]; then
            log "Error: Destination file exists. Use --force to overwrite or --backup to create backup."
            return 1
        fi
    fi
    
    # Check optional tools
    if ! command -v cmp >/dev/null; then
        log "Warning: 'cmp' is not installed. File comparison may not work."
        NO_CMP=1
    else
        NO_CMP=0
    fi
    
    # Set up SSH authentication for sudo environment if not already set
    if [ -n "$SUDO_USER" ] && [ -z "$GIT_SSH_COMMAND" ]; then
        export GIT_SSH_COMMAND="ssh -i $REAL_HOME/.ssh/id_rsa"
        log "Using SSH key: $REAL_HOME/.ssh/id_rsa"
    fi
    
    # Set up temporary directory for git operations
    local git_tmp_dir="$TEMP_DIR/liteflow_git.$PACKAGE_KEY"
    
    # Clone or update repository
    if [ -d "$git_tmp_dir/.git" ]; then
        log "Updating existing git repo at $git_tmp_dir"
        cd "$git_tmp_dir" || return 1
        git remote set-url origin "$repo_url" || true
        git pull origin --depth=1 || {
            log "Error: Failed to pull from git repo"
            cd - >/dev/null || true
            return 1
        }
        git reset --hard origin/HEAD || {
            log "Error: Failed to reset git repo"
            cd - >/dev/null || true
            return 1
        }
        cd - >/dev/null || return 1
    else
        log "Cloning fresh repo to $git_tmp_dir"
        rm -rf "$git_tmp_dir"
        if ! git clone --depth=1 "$repo_url" "$git_tmp_dir"; then
            log "Error: Failed to clone git repo"
            return 1
        fi
    fi
    
    # Check if source file exists in repo
    local src_file="$git_tmp_dir/$src_path"
    if [ ! -f "$src_file" ]; then
        log "Error: File $src_path does not exist in repo"
        return 1
    fi
    
    
    # Compare and copy file
    if [ "$NO_CMP" -eq 0 ] && [ -f "$dest_path" ]; then
        if ! cmp -s "$src_file" "$dest_path"; then
            log "Updating $dest_path with new version from repo"
            cp "$src_file" "$dest_path" || {
                log "Error: Failed to copy file"
                return 1
            }
        else
            log "No changes detected in config file"
        fi
    else
        if [ "$NO_CMP" -eq 1 ] && [ -f "$dest_path" ]; then
            log "cmp not available, overwriting $dest_path without comparison"
        else
            log "Creating $dest_path from repo"
        fi
        
        # Create destination directory if needed
        local dest_dir=$(dirname "$dest_path")
        mkdir -p "$dest_dir" || {
            log "Error: Failed to create destination directory"
            return 1
        }
        
        cp "$src_file" "$dest_path" || {
            log "Error: Failed to copy file"
            return 1
        }
    fi
    
    log "Successfully pulled configuration from git repo"
    return 0
}

usage_git() {
    local script_name=$(basename "$0")
    log "Usage: $script_name git [options] <repo_url> <src_path> <dest_path>" >&2
    log "Options:" >&2
    log "  --force     Overwrite existing destination file" >&2
    log "  --backup    Create backup with timestamp before overwriting" >&2
    log "Examples:" >&2
    log "  $script_name git git@github.com:user/configs.git server.conf /etc/liteflow.conf" >&2
    log "  $script_name git --backup https://github.com/user/configs.git client.conf ./liteflow.conf" >&2
}

usage_wget() {
    local script_name=$(basename "$0")
    log "Usage: $script_name wget [options] <url> <dest_path>" >&2
    log "Options:" >&2
    log "  --force     Overwrite existing destination file" >&2
    log "  --backup    Create backup with timestamp before overwriting" >&2
    log "Examples:" >&2
    log "  $script_name wget https://example.com/liteflow.conf /etc/liteflow.conf" >&2
    log "  $script_name wget --backup https://configs.example.com/server.json ./liteflow.conf" >&2
}

usage() {
    local script_name=$(basename "$0")
    log "Usage: $script_name <subcommand> [options] <args...>" >&2
    log "Subcommands:" >&2
    log "  git     pull configuration from git repository" >&2
    log "  wget    pull configuration from HTTP/HTTPS URL" >&2
    log "" >&2
    log "Run '$script_name <subcommand>' for subcommand-specific help." >&2
    exit 1
}

# Main logic
if [ $# -eq 0 ]; then
    usage
fi

subcommand="$1"
shift

# Check required commands for the subcommand
if ! check_required_commands "$subcommand"; then
    exit 1
fi

case "$subcommand" in
    git)
        pull_git "$@"
        ;;
    wget)
        pull_wget "$@"
        ;;
    *)
        log "Error: Unknown subcommand '$subcommand'"
        usage
        ;;
esac

exit $?
