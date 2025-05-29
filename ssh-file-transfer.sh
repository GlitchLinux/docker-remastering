#!/bin/bash

# Function to display error and exit
error_exit() {
    local message="$1"
    echo -e "\nERROR: $message" >&2
    exit 1
}

# Function to check dependencies
check_dependencies() {
    local missing=()
    
    if ! command -v sshpass &> /dev/null; then
        missing+=("sshpass")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        error_exit "Missing required packages: ${missing[*]}\nInstall with: sudo apt install ${missing[*]}"
    fi
}

# Function to validate ISO file
validate_iso() {
    local iso_file="$1"
    if [ ! -f "$iso_file" ]; then
        error_exit "ISO file not found: $iso_file"
    fi
    if [ ! -r "$iso_file" ]; then
        error_exit "No read permission for ISO file: $iso_file"
    fi
    if ! file "$iso_file" | grep -q "ISO 9660"; then
        echo "Warning: $iso_file doesn't appear to be a valid ISO 9660 file"
        read -p "Continue anyway? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
    fi
}

# Function to test SSH connection
test_ssh_connection() {
    echo -n "Testing SSH connection to $host... "
    if ! sshpass -p "$password" ssh -o StrictHostKeyChecking=no -p "$port" "$username@$host" "exit" &>/dev/null; then
        echo "FAILED"
        error_exit "SSH connection failed! Check credentials and try again."
    fi
    echo "OK"
}

# Function to calculate file size in human readable format
human_readable_size() {
    local size=$1
    if [ $size -ge 1073741824 ]; then
        echo "$(bc <<< "scale=2; $size/1073741824") GB"
    elif [ $size -ge 1048576 ]; then
        echo "$(bc <<< "scale=2; $size/1048576") MB"
    elif [ $size -ge 1024 ]; then
        echo "$(bc <<< "scale=2; $size/1024") KB"
    else
        echo "$size bytes"
    fi
}

# Function to transfer file with progress
transfer_file() {
    local source_file="$1"
    local destination="$2"
    local use_sudo="$3"
    local file_size=$(stat -c %s "$source_file")
    local human_size=$(human_readable_size $file_size)

    echo -e "\nTransferring file: ${source_file##*/} ($human_size)"
    echo "Destination: $host:$destination"
    [ "$use_sudo" = true ] && echo "Using sudo for transfer"
    
    # Create a named pipe for progress monitoring
    PIPE=$(mktemp -u)
    mkfifo "$PIPE"
    
    # Background process to show progress
    (
        while true; do
            # Get current transferred size from the pipe
            read -r current < "$PIPE"
            if [ "$current" == "DONE" ]; then
                break
            fi
            percent=$((current * 100 / file_size))
            printf "\rProgress: [%-50s] %d%%" "$(printf '#%.0s' $(seq 1 $((percent/2))))" "$percent"
        done
    ) &
    progress_pid=$!
    
    if [ "$use_sudo" = true ]; then
        # Create temp directory
        temp_dir="/tmp/ssh_transfer_$(date +%s)"
        if ! sshpass -p "$password" ssh -p "$port" "$username@$host" "mkdir -p '$temp_dir'"; then
            echo -e "\nFailed to create temp directory on server"
            rm -f "$PIPE"
            kill $progress_pid 2>/dev/null
            exit 1
        fi

        # Transfer with progress monitoring
        (
            dd if="$source_file" bs=4K 2>/dev/null | \
            sshpass -p "$password" ssh -p "$port" "$username@$host" "cat > '$temp_dir/${source_file##*/}'"
            echo "DONE" > "$PIPE"
        ) &
        transfer_pid=$!
        
        # Monitor local file for progress
        while kill -0 $transfer_pid 2>/dev/null; do
            current=$(stat -c %s "$source_file" 2>/dev/null || echo 0)
            echo "$current" > "$PIPE"
            sleep 1
        done

        # Move with sudo
        printf "\nMoving to final destination with sudo... "
        if ! sshpass -p "$password" ssh -p "$port" "$username@$host" \
            "sudo mkdir -p '$(dirname "$destination")' && sudo cp '$temp_dir/${source_file##*/}' '$destination' && sudo rm -rf '$temp_dir'"; then
            echo "FAILED"
            rm -f "$PIPE"
            kill $progress_pid 2>/dev/null
            exit 1
        fi
        echo "OK"
    else
        # Direct transfer with progress
        (
            dd if="$source_file" bs=4K 2>/dev/null | \
            sshpass -p "$password" ssh -p "$port" "$username@$host" "mkdir -p '$(dirname "$destination")' && cat > '$destination'"
            echo "DONE" > "$PIPE"
        ) &
        transfer_pid=$!
        
        # Monitor local file for progress
        while kill -0 $transfer_pid 2>/dev/null; do
            current=$(stat -c %s "$source_file" 2>/dev/null || echo 0)
            echo "$current" > "$PIPE"
            sleep 1
        done
    fi
    
    # Clean up
    wait $progress_pid
    rm -f "$PIPE"
    printf "\rTransfer completed successfully! %50s\n" " "
}

# Main script
main() {
    # Check if running as root
    if [ "$(id -u)" -eq 0 ]; then
        error_exit "This script should not be run as root."
    fi

    # Check if /home/snapshot exists
    if [ ! -d "/home/snapshot" ]; then
        error_exit "/home/snapshot directory not found."
    fi

    # List available ISO files in /home/snapshot/
    echo "Available ISO files in /home/snapshot/:"
    mapfile -t iso_files < <(find /home/snapshot/ -maxdepth 1 -type f -name "*.iso" 2>/dev/null | sort)
    
    if [ ${#iso_files[@]} -eq 0 ]; then
        error_exit "No ISO files found in /home/snapshot/"
    fi
    
    for i in "${!iso_files[@]}"; do
        size=$(stat -c %s "${iso_files[$i]}")
        human_size=$(human_readable_size $size)
        printf "%2d) %-50s %10s\n" "$((i+1))" "${iso_files[$i]##*/}" "$human_size"
    done
    
    # Prompt user to select an ISO file
    while true; do
        read -p "Select an ISO file to copy (1-${#iso_files[@]} or 'q' to quit): " choice
        [[ "$choice" =~ ^[Qq]$ ]] && exit 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#iso_files[@]} ]; then
            break
        fi
        echo "Invalid selection. Please enter a number between 1 and ${#iso_files[@]} or 'q' to quit."
    done
    
    selected_iso="${iso_files[$((choice-1))]}"
    validate_iso "$selected_iso"
    iso_name="${selected_iso##*/}"
    iso_size=$(human_readable_size $(stat -c %s "$selected_iso"))
    
    # Copy ISO to /home/
    echo -e "\nSelected: $iso_name ($iso_size)"
    echo "Copying to /home/ ..."
    cp -v "$selected_iso" "/home/$iso_name" || error_exit "Failed to copy ISO file."
    
    # Prompt for new name with validation
    while true; do
        read -p "Enter a new name for the ISO file (without .iso extension): " custom_name
        custom_name=$(echo "$custom_name" | tr -d '[:space:]')
        if [ -z "$custom_name" ]; then
            echo "Name cannot be empty."
            continue
        fi
        if [[ "$custom_name" =~ [/\\:\*\?\"<>\|] ]]; then
            echo "Invalid characters in name. Please avoid / \ : * ? \" < > |"
            continue
        fi
        if [ -e "/home/${custom_name}.iso" ]; then
            read -p "File /home/${custom_name}.iso already exists. Overwrite? [y/N]: " overwrite
            [[ "$overwrite" =~ ^[Yy]$ ]] || continue
        fi
        break
    done
    
    new_iso="/home/${custom_name}.iso"
    mv -v "/home/$iso_name" "$new_iso" || error_exit "Failed to rename ISO file."
    echo -e "\nISO file ready for transfer: $new_iso"
    
    # Check dependencies for SSH transfer
    check_dependencies
    
    # Get SSH credentials with validation
    while true; do
        read -p "Enter SSH credentials (user@host): " credentials
        [[ "$credentials" =~ ^[Qq]$ ]] && exit 0
        if [[ "$credentials" =~ ^[^@]+@[^@]+$ ]]; then
            username=${credentials%%@*}
            host=${credentials#*@}
            break
        fi
        echo "Invalid format! Please use user@host format or 'q' to quit."
    done

    # Get password securely
    while true; do
        read -s -p "Enter password for $credentials: " password
        echo
        [ -z "$password" ] && echo "Password cannot be empty." || break
    done

    # Get SSH port with validation
    while true; do
        read -p "Enter SSH port [22]: " port
        port=${port:-22}
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            break
        fi
        echo "Invalid port number. Must be between 1 and 65535."
    done

    # Test SSH connection
    test_ssh_connection

    # Get destination path with validation
    while true; do
        read -p "Enter destination path on remote host: " destination
        destination=$(echo "$destination" | sed 's:/*$::')  # Remove trailing slashes
        [[ "$destination" =~ ^[Qq]$ ]] && exit 0
        if [ -z "$destination" ]; then
            echo "Destination path cannot be empty."
            continue
        fi
        if ! [[ "$destination" =~ ^/ ]]; then
            echo "Destination path must be absolute (start with /)."
            continue
        fi
        break
    done

    # Check if destination requires sudo
    use_sudo=false
    if [[ "$destination" =~ ^/(etc|usr|lib|var|bin|sbin|opt|root|boot|dev|proc|sys|tmp) ]]; then
        read -p "The destination appears to be system-protected. Use sudo for transfer? [y/N]: " sudo_choice
        [[ "$sudo_choice" =~ ^[Yy]$ ]] && use_sudo=true
    fi

    # Confirm transfer
    echo -e "\n=== Transfer Summary ==="
    echo "Source:      $new_iso"
    echo "Destination: $host:$destination"
    echo "SSH Port:    $port"
    [ "$use_sudo" = true ] && echo "Privilege:   sudo"
    echo "Size:        $iso_size"
    read -p "Confirm transfer? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0

    # Perform transfer
    transfer_file "$new_iso" "$destination" "$use_sudo"

    # Verify transfer
    echo -e "\n=== Transfer Verification ==="
    echo -n "Verifying remote file... "
    remote_size=$(sshpass -p "$password" ssh -p "$port" "$username@$host" \
        "stat -c %s '$destination' 2>/dev/null || echo 0")
    
    if [ "$remote_size" -eq $(stat -c %s "$new_iso") ]; then
        echo "OK - File size matches"
    else
        echo "WARNING - File size mismatch"
        echo "Local size:  $(stat -c %s "$new_iso")"
        echo "Remote size: $remote_size"
    fi
}

main