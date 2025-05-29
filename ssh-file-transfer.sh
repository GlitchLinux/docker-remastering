#!/bin/bash

# Function to display error and exit
error_exit() {
    echo -e "\nERROR: $1" >&2
    exit 1
}

# Function to check dependencies
check_dependencies() {
    local missing=()
    ! command -v sshpass &>/dev/null && missing+=("sshpass")
    ! command -v pv &>/dev/null && missing+=("pv")  # For progress tracking
    [ ${#missing[@]} -gt 0 ] && error_exit "Missing packages: ${missing[*]}\nInstall with: sudo apt install ${missing[*]}"
}

# Function to test SSH connection
test_connection() {
    echo -n "Testing SSH connection to $host... "
    if ! sshpass -p "$password" ssh -o StrictHostKeyChecking=no -p "$port" "$username@$host" "exit" &>/dev/null; then
        echo "FAILED"
        error_exit "Connection failed. Check:\n1. Credentials\n2. Server reachability\n3. SSH service\n4. Firewall rules for port $port"
    fi
    echo "OK"
}

# Function to transfer with reliable progress
transfer_file() {
    local src="$1"
    local dest="$2"
    local size=$(stat -c %s "$src")
    local temp_dir="/tmp/iso_transfer_$(date +%s)"
    
    echo -e "\nTransferring ${src##*/} ($(numfmt --to=iec-i --suffix=B $size))"
    echo "Destination: $host:$dest"

    if [ "$use_sudo" = true ]; then
        echo "Using sudo for transfer..."
        # Create temp directory
        if ! sshpass -p "$password" ssh -p "$port" "$username@$host" "mkdir -p '$temp_dir'"; then
            error_exit "Failed to create temp directory on remote"
        fi

        # Transfer with progress
        if ! pv -pet -s $size "$src" | \
           sshpass -p "$password" ssh -p "$port" "$username@$host" "cat > '$temp_dir/${src##*/}'"; then
            error_exit "Failed to transfer file to temp location"
        fi

        # Move with sudo
        if ! sshpass -p "$password" ssh -p "$port" "$username@$host" \
            "sudo mkdir -p '$(dirname "$dest")' && \
             sudo cp '$temp_dir/${src##*/}' '$dest' && \
             sudo rm -rf '$temp_dir'"; then
            error_exit "Failed to move file with sudo"
        fi
    else
        echo "Direct transfer..."
        if ! pv -pet -s $size "$src" | \
           sshpass -p "$password" ssh -p "$port" "$username@$host" \
           "mkdir -p '$(dirname "$dest")' && cat > '$dest'"; then
            error_exit "Direct transfer failed"
        fi
    fi

    echo -e "\nTransfer completed successfully!"
}

# Main script
main() {
    # Check for ISO files
    iso_files=(/home/snapshot/snapshot-*.iso)
    if [ ${#iso_files[@]} -eq 0 ]; then
        error_exit "No snapshot ISO files found in /home/snapshot/"
    fi

    # Select ISO file
    echo "Available snapshot ISOs:"
    PS3="Select a file (1-${#iso_files[@]}): "
    select iso in "${iso_files[@]}"; do
        [ -n "$iso" ] && break
        echo "Invalid selection. Try again."
    done

    # Verify ISO exists
    [ ! -f "$iso" ] && error_exit "Selected ISO file not found: $iso"

    # Copy to root with timestamp
    new_name="custom_$(date +%Y%m%d_%H%M).iso"
    echo -e "\nCopying ${iso##*/} to /$new_name"
    sudo cp -v "$iso" "/$new_name" || error_exit "Failed to copy ISO to root"
    local iso_path="/$new_name"

    # SSH transfer setup
    check_dependencies

    # Get credentials
    while true; do
        read -p "SSH credentials (user@host): " credentials
        [[ "$credentials" =~ ^[^@]+@[^@]+$ ]] && break
        echo "Invalid format. Use: username@hostname"
    done
    username=${credentials%%@*}
    host=${credentials#*@}

    read -s -p "Password: " password
    echo
    [ -z "$password" ] && error_exit "Password required"

    while true; do
        read -p "SSH port [22]: " port
        port=${port:-22}
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] && [ "$port" -lt 65536 ] && break
        echo "Invalid port number (1-65535)"
    done

    test_connection

    # Destination path
    while true; do
        read -p "Remote destination path: " dest_path
        dest_path=$(echo "$dest_path" | sed 's:/*$::')  # Remove trailing slashes
        [ -n "$dest_path" ] && break
        echo "Destination path required"
    done

    # Check for system directories
    use_sudo=false
    if [[ "$dest_path" =~ ^/(etc|usr|lib|var|bin|sbin|opt|root|boot) ]]; then
        read -p "System directory detected. Use sudo? [y/N]: " sudo_confirm
        [[ "$sudo_confirm" =~ ^[Yy]$ ]] && use_sudo=true
    fi

    # Confirm transfer
    echo -e "\n=== Transfer Summary ==="
    echo "File: ${iso_path##*/}"
    echo "Size: $(numfmt --to=iec-i --suffix=B $(stat -c %s "$iso_path"))"
    echo "From: $(hostname)"
    echo "To: $host:$dest_path"
    echo "SSH Port: $port"
    [ "$use_sudo" = true ] && echo "Privilege: sudo"

    read -p "Confirm transfer? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

    transfer_file "$iso_path" "$dest_path" "$use_sudo"

    # Verify transfer
    echo -n "Verifying transfer... "
    remote_size=$(sshpass -p "$password" ssh -p "$port" "$username@$host" \
        "stat -c %s '$dest_path' 2>/dev/null || echo 0")
    local_size=$(stat -c %s "$iso_path")
    
    if [ "$remote_size" -eq "$local_size" ]; then
        echo "Success! File sizes match."
    else
        echo "WARNING: Size mismatch!"
        echo "Local size:  $(numfmt --to=iec-i --suffix=B $local_size)"
        echo "Remote size: $(numfmt --to=iec-i --suffix=B $remote_size)"
    fi

    # Cleanup
    read -p "Delete local copy $iso_path? [y/N]: " cleanup
    [[ "$cleanup" =~ ^[Yy]$ ]] && sudo rm -v "$iso_path"
}

main
