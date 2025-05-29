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
    [ ${#missing[@]} -gt 0 ] && error_exit "Missing packages: ${missing[*]}\nInstall with: sudo apt install ${missing[*]}"
}

# Function to test SSH connection
test_connection() {
    echo -n "Testing SSH connection... "
    if ! sshpass -p "$password" ssh -o StrictHostKeyChecking=no -p "$port" "$username@$host" "exit" &>/dev/null; then
        echo "FAILED"
        error_exit "Connection failed. Check credentials and try again."
    fi
    echo "OK"
}

# Function to transfer with progress
transfer_file() {
    local src="$1"
    local dest="$2"
    local size=$(stat -c %s "$src")
    local temp_dir="/tmp/iso_transfer_$(date +%s)"
    
    echo -e "\nTransferring ${src##*/} ($(numfmt --to=iec-i --suffix=B $size))"
    echo "Destination: $host:$dest"
    
    # Create progress pipe
    mkfifo /tmp/transfer_progress
    (
        while true; do
            read -r current < /tmp/transfer_progress
            [ "$current" = "DONE" ] && break
            printf "\rProgress: [%-50s] %d%%" \
                   "$(printf '#%.0s' $(seq 1 $((current*50/size))))" \
                   $((current*100/size))
        done
    ) &
    
    # Transfer file
    if [ "$use_sudo" = true ]; then
        sshpass -p "$password" ssh -p "$port" "$username@$host" "mkdir -p '$temp_dir'"
        dd if="$src" 2>/dev/null | \
        sshpass -p "$password" ssh -p "$port" "$username@$host" \
            "cat > '$temp_dir/${src##*/}'; \
             sudo mkdir -p '$(dirname "$dest")' && \
             sudo mv '$temp_dir/${src##*/}' '$dest' && \
             sudo rm -rf '$temp_dir'"
    else
        dd if="$src" 2>/dev/null | \
        sshpass -p "$password" ssh -p "$port" "$username@$host" \
            "mkdir -p '$(dirname "$dest")' && cat > '$dest'"
    fi
    
    # Cleanup
    echo "DONE" > /tmp/transfer_progress
    wait
    rm -f /tmp/transfer_progress
    echo -e "\rTransfer completed successfully! $(tput el)"
}

# Main script
main() {
    # Check for ISO files
    iso_files=(/home/snapshot/snapshot-*.iso)
    [ ${#iso_files[@]} -eq 0 ] && error_exit "No snapshot ISO files found in /home/snapshot/"
    
    # Select ISO file
    echo "Available snapshot ISOs:"
    PS3="Select a file (1-${#iso_files[@]}): "
    select iso in "${iso_files[@]}"; do
        [ -n "$iso" ] && break
        echo "Invalid selection. Try again."
    done
    
    # Copy to root
    echo -e "\nSelected: ${iso##*/}"
    sudo cp -v "$iso" / || error_exit "Failed to copy ISO to root"
    
    # Rename ISO
    while true; do
        read -p "Enter new name (without .iso extension): " new_name
        new_name=$(echo "$new_name" | tr -d '[:space:]')
        [ -z "$new_name" ] && echo "Name cannot be empty" && continue
        [[ "$new_name" =~ [/\\] ]] && echo "Invalid characters" && continue
        break
    done
    
    sudo mv -v "/${iso##*/}" "/$new_name.iso" || error_exit "Failed to rename ISO"
    local iso_path="/$new_name.iso"
    
    # SSH transfer setup
    check_dependencies
    
    # Get credentials
    while true; do
        read -p "SSH credentials (user@host): " credentials
        [[ "$credentials" =~ ^[^@]+@[^@]+$ ]] && break
        echo "Format: user@host"
    done
    username=${credentials%%@*}
    host=${credentials#*@}
    
    read -s -p "Password: " password
    echo
    [ -z "$password" ] && error_exit "Password required"
    
    read -p "SSH port [22]: " port
    port=${port:-22}
    
    test_connection
    
    # Destination path
    while true; do
        read -p "Remote destination path: " dest_path
        [ -n "$dest_path" ] && break
        echo "Path required"
    done
    
    # Check for system directories
    use_sudo=false
    [[ "$dest_path" =~ ^/(etc|usr|lib|var|bin|sbin|opt|root|boot) ]] && \
        read -p "System directory detected. Use sudo? [y/N]: " sudo_confirm && \
        [[ "$sudo_confirm" =~ ^[Yy]$ ]] && use_sudo=true
    
    # Confirm and transfer
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
    
    # Verify
    echo -n "Verifying transfer... "
    remote_size=$(sshpass -p "$password" ssh -p "$port" "$username@$host" \
        "stat -c %s '$dest_path' 2>/dev/null || echo 0")
    [ "$remote_size" -eq $(stat -c %s "$iso_path") ] && echo "Success!" || echo "Size mismatch!"
}

main
