#!/bin/bash
#
# Whonix Proxmox Setup Script
# Automates deployment of Whonix Gateway and Workstation VMs on Proxmox VE
#
# Version: 1.0.0
# License: MIT
#

set -e
set -u
set -o pipefail

# =============================================================================
# VERSION AND CONSTANTS
# =============================================================================
VERSION="1.0.1"
SCRIPT_NAME="whonix-proxmox-setup.sh"
LOG_FILE="/var/log/whonix-setup.log"
# Whonix Gateway download URLs
GATEWAY_DOWNLOAD_URL="https://mirrors.dotsrc.org/whonix/libvirt/18.1.4.2/Whonix-Gateway-18.1.4.2.qcow2.xz"
GATEWAY_CHECKSUM_URL="https://mirrors.dotsrc.org/whonix/libvirt/18.1.4.2/Whonix-Gateway-18.1.4.2.qcow2.xz.asc"

# Whonix Workstation download URLs
WORKSTATION_DOWNLOAD_URL="https://mirrors.dotsrc.org/whonix/libvirt/18.1.4.2/Whonix-Workstation-18.1.4.2.qcow2.xz"
WORKSTATION_CHECKSUM_URL="https://mirrors.dotsrc.org/whonix/libvirt/18.1.4.2/Whonix-Workstation-18.1.4.2.qcow2.xz.asc"

WHONIX_VERSION="18.1.4.2"

# =============================================================================
# DEFAULT CONFIGURATION - User configurable section
# =============================================================================

# Storage Configuration
STORAGE_ISO="local"
STORAGE_DISK="local-lvm"

# Resource Allocation - Gateway
GATEWAY_CPU=1
GATEWAY_RAM=512
GATEWAY_DISK_SIZE=10

# Resource Allocation - Workstation
WORKSTATION_CPU=2
WORKSTATION_RAM=2048
WORKSTATION_DISK_SIZE=20

# VM Names
GATEWAY_NAME="Whonix-Gateway"
WORKSTATION_NAME="Whonix-Workstation"

# VM IDs (empty = auto-assign)
GATEWAY_VM_ID=""
WORKSTATION_VM_ID=""

# Network Configuration
EXTERNAL_BRIDGE="vmbr0"
INTERNAL_BRIDGE="vmbr1"
CREATE_INTERNAL_BRIDGE=true

# VM Options
AUTOSTART=true
BIOS_TYPE="seabios"
QEMU_AGENT=false

# Script Behavior
DRY_RUN=false
SKIP_CONFIRM=false

# =============================================================================
# COLOR CODES AND UTILITIES
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

log_info() {
    log "INFO" "$1"
}

log_error() {
    log "ERROR" "$1"
}

log_warn() {
    log "WARN" "$1"
}

print_colored() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

print_success() {
    print_colored "$GREEN" "✓ $1"
}

print_error() {
    print_colored "$RED" "✗ ERROR: $1"
}

print_warning() {
    print_colored "$YELLOW" "⚠ WARNING: $1"
}

print_info() {
    print_colored "$BLUE" "ℹ $1"
}

print_step() {
    print_colored "$CYAN" "${BOLD}→ $1${NC}"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Get next available VM ID
get_next_vm_id() {
    local next_id=$(pvesh get /cluster/nextid 2>/dev/null)
    if [ -n "$next_id" ]; then
        echo "$next_id"
    else
        # Fallback: find first available ID starting from 100
        local id=100
        while qm status $id &>/dev/null; do
            ((id++))
        done
        echo "$id"
    fi
}

# Check if VM ID is available
vm_id_available() {
    local vm_id="$1"
    if qm status "$vm_id" &>/dev/null; then
        return 1
    fi
    return 0
}

# Validate VM ID
validate_vm_id() {
    local vm_id="$1"
    local vm_name="$2"
    
    # Check if ID is a number
    if ! [[ "$vm_id" =~ ^[0-9]+$ ]]; then
        print_error "Invalid VM ID '$vm_id' for $vm_name - must be a number"
        return 1
    fi
    
    # Check range
    if [ "$vm_id" -lt 100 ] || [ "$vm_id" -gt 999999 ]; then
        print_error "VM ID '$vm_id' for $vm_name is out of valid range (100-999999)"
        return 1
    fi
    
    # Check availability
    if ! vm_id_available "$vm_id"; then
        print_error "VM ID '$vm_id' for $vm_name is already in use"
        return 1
    fi
    
    return 0
}

# List available storage backends
list_available_storages() {
    print_info "Available Storage Backends:"
    print_colored "$CYAN" "----------------------------------------------"
    printf "%-15s %-10s %-10s %-10s %-10s\n" "Name" "Type" "Total(GB)" "Used(GB)" "Avail(GB)"
    print_colored "$CYAN" "----------------------------------------------"
    
    pvesm status | tail -n +2 | while read -r name type total used avail rest; do
        if [ -n "$name" ]; then
            printf "%-15s %-10s %-10s %-10s %-10s\n" "$name" "$type" "$total" "$used" "$avail"
        fi
    done
    print_colored "$CYAN" "----------------------------------------------"
}

# Check if storage exists
storage_exists() {
    local storage="$1"
    pvesm status | grep -q "^$storage "
}

# Check if VM name exists
vm_name_exists() {
    local name="$1"
    qm list | grep -q " $name$"
}

# Get VM ID by name
get_vm_id_by_name() {
    local name="$1"
    qm list | grep " $name$" | awk '{print $1}'
}

# =============================================================================
# PROGRESS BAR FUNCTIONS
# =============================================================================

show_progress() {
    local current=$1
    local total=$2
    local width=40
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r  ["
    printf '%0.s█' $(seq 1 $filled 2>/dev/null) || true
    printf '%0.s░' $(seq 1 $empty 2>/dev/null) || true
    printf "] %3d%% (%s/%s)" "$percentage" "$(format_size $current)" "$(format_size $total)"
}

format_size() {
    local size=$1
    if [ $size -ge 1073741824 ]; then
        echo "$(echo $size | awk '{printf "%.1f GB", $1/1073741824}')"
    elif [ $size -ge 1048576 ]; then
        echo "$(echo $size | awk '{printf "%.1f MB", $1/1048576}')"
    elif [ $size -ge 1024 ]; then
        echo "$(echo $size | awk '{printf "%.1f KB", $1/1024}')"
    else
        echo "${size} B"
    fi
}

# =============================================================================
# CONFIRMATION FUNCTIONS
# =============================================================================

confirm() {
    local message="$1"
    if [ "$SKIP_CONFIRM" = true ]; then
        return 0
    fi
    
    print_warning "$message"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

check_prerequisites() {
    print_step "Checking prerequisites..."
    local errors=0
    
    # Check if running on Proxmox
    if ! command -v pvesh &>/dev/null; then
        print_error "pvesh command not found. Are you running on Proxmox?"
        ((errors++))
    fi
    
    # Check for root privileges
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        ((errors++))
    fi
    
    # Check that we're running on the local node only
    local local_node=$(hostname)
    # Get the node we're currently running on from the Proxmox API
    local current_node=$(pvesh get /nodes/localhost/status --output-format json 2>/dev/null | jq -r '.nodename' 2>/dev/null)
    
    # If we can't get the current node from localhost, try to get it from the node list
    if [ -z "$current_node" ] || [ "$current_node" = "null" ]; then
        current_node=$(pvesh get /nodes --output-format json 2>/dev/null | jq -r '.[] | select(.online==1) | .node' 2>/dev/null | head -1)
    fi
    
    # If we still can't determine the current node, but we're on a Proxmox system, proceed
    # Otherwise, if we have both values and they don't match, error
    if [ -n "$current_node" ] && [ "$current_node" != "null" ] && [ -n "$local_node" ] && [ "$current_node" != "$local_node" ]; then
        print_error "This script must be run on the local Proxmox node. Detected node: $current_node, Local hostname: $local_node"
        ((errors++))
    fi
    
    # Check for required commands
    for cmd in qm pvesh wget curl tar xz jq; do
        if ! command -v $cmd &>/dev/null; then
            print_error "Required command '$cmd' not found"
            ((errors++))
        fi
    done
    
    # Check storage backends
    if ! storage_exists "$STORAGE_ISO"; then
        print_error "ISO storage '$STORAGE_ISO' does not exist"
        print_info "Available storages:"
        pvesm status | head -10
        ((errors++))
    fi
    
    if ! storage_exists "$STORAGE_DISK"; then
        print_error "Disk storage '$STORAGE_DISK' does not exist"
        print_info "Available storages:"
        pvesm status | head -10
        ((errors++))
    fi
    
    if [ $errors -gt 0 ]; then
        print_error "Prerequisites check failed with $errors error(s)"
        return 1
    fi
    
    print_success "Prerequisites check passed"
    return 0
}

# =============================================================================
# STORAGE SELECTION
# =============================================================================

select_storage() {
    if [ "$SKIP_CONFIRM" = false ]; then
        list_available_storages
        echo ""
        print_info "Current storage configuration:"
        echo "  ISO Storage:   $STORAGE_ISO"
        echo "  Disk Storage:  $STORAGE_DISK"
        echo ""
        confirm "Use these storage settings?" || {
            read -p "Enter ISO storage name (default: $STORAGE_ISO): " iso_storage
            read -p "Enter Disk storage name (default: $STORAGE_DISK): " disk_storage
            [ -n "$iso_storage" ] && STORAGE_ISO="$iso_storage"
            [ -n "$disk_storage" ] && STORAGE_DISK="$disk_storage"
        }
    fi
}

# =============================================================================
# NETWORK BRIDGE FUNCTIONS
# =============================================================================

create_internal_bridge() {
    if [ "$CREATE_INTERNAL_BRIDGE" = false ]; then
        print_info "Skipping internal bridge creation (user specified)"
        return 0
    fi
    
    print_step "Creating internal network bridge ($INTERNAL_BRIDGE)..."
    
    # Check if bridge already exists
    if ip link show $INTERNAL_BRIDGE &>/dev/null; then
        print_info "Bridge $INTERNAL_BRIDGE already exists"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would create bridge $INTERNAL_BRIDGE"
        return 0
    fi
    
    # Check if we're on Proxmox and can use pvesh
    if command -v pvesh &>/dev/null; then
        # Try to create bridge using Proxmox API
        print_info "Creating bridge using Proxmox API..."
        if pvesh create /nodes/$(hostname)/network -name $INTERNAL_BRIDGE -type bridge -autostart 1 &>/dev/null; then
            print_success "Internal bridge $INTERNAL_BRIDGE created via API"
            log_info "Created internal bridge $INTERNAL_BRIDGE via API"
            return 0
        else
            print_warning "Failed to create bridge via API, falling back to manual method"
        fi
    fi
    
    # Fallback: Create the bridge configuration manually
    print_info "Creating bridge configuration manually..."
    
    # Check if config directory exists
    if [ ! -d "/etc/network/interfaces.d" ]; then
        mkdir -p /etc/network/interfaces.d
    fi
    
    # Create the bridge configuration
    cat > /etc/network/interfaces.d/$INTERNAL_BRIDGE.conf << EOF
auto $INTERNAL_BRIDGE
iface $INTERNAL_BRIDGE inet manual
    bridge_ports none
    bridge_stp off
    bridge_fd 0
    bridge_vlan_aware yes
EOF
    
    # Try to bring up the bridge
    if command -v ifup &>/dev/null; then
        if ifup $INTERNAL_BRIDGE; then
            print_success "Internal bridge $INTERNAL_BRIDGE created and activated"
            log_info "Created internal bridge $INTERNAL_BRIDGE manually"
            return 0
        else
            print_error "Failed to activate bridge $INTERNAL_BRIDGE"
            return 1
        fi
    else
        # Try alternative method
        if ip link add name $INTERNAL_BRIDGE type bridge && ip link set $INTERNAL_BRIDGE up; then
            print_success "Internal bridge $INTERNAL_BRIDGE created using ip command"
            log_info "Created internal bridge $INTERNAL_BRIDGE using ip command"
            return 0
        else
            print_error "Failed to create bridge $INTERNAL_BRIDGE"
            return 1
        fi
    fi
}

# =============================================================================
# DOWNLOAD FUNCTIONS
# =============================================================================

download_whonix_images() {
    local gateway_download_path="/root/whonix-gateway.qcow2.xz"
    local gateway_extracted_path="/root/whonix-gateway.qcow2"
    local gateway_checksum_path="/root/whonix-gateway.sha256"
    
    local workstation_download_path="/root/whonix-workstation.qcow2.xz"
    local workstation_extracted_path="/root/whonix-workstation.qcow2"
    local workstation_checksum_path="/root/whonix-workstation.sha256"

    print_step "Downloading Whonix images..."

    # Download Gateway image
    if ! download_single_image "Gateway" "$GATEWAY_DOWNLOAD_URL" "$GATEWAY_CHECKSUM_URL" "$gateway_download_path" "$gateway_extracted_path" "$gateway_checksum_path"; then
        return 1
    fi

    # Download Workstation image
    if ! download_single_image "Workstation" "$WORKSTATION_DOWNLOAD_URL" "$WORKSTATION_CHECKSUM_URL" "$workstation_download_path" "$workstation_extracted_path" "$workstation_checksum_path"; then
        return 1
    fi

    print_success "All Whonix images downloaded and extracted"
}

download_single_image() {
    local image_type="$1"
    local download_url="$2"
    local checksum_url="$3"
    local download_path="$4"
    local extracted_path="$5"
    local checksum_path="$6"

    print_info "Downloading Whonix $image_type image..."

    # Check if already downloaded and valid
    if [ -f "$extracted_path" ]; then
        print_info "Whonix $image_type image already downloaded"
        return 0
    fi
    
    # If we have a download but no extracted file, try to extract it
    if [ -f "$download_path" ] && [ ! -f "$extracted_path" ]; then
        print_info "Found existing $image_type download, extracting..."
        if xz -d -k "$download_path" 2>/dev/null; then
            print_success "$image_type extraction completed"
            return 0
        else
            print_warning "Failed to extract existing $image_type download, re-downloading..."
            rm -f "$download_path" "$checksum_path" 2>/dev/null || true
        fi
    fi

    if [ -f "$download_path" ]; then
        print_info "Found existing $image_type download, verifying..."
        local needs_redownload=false

        # Verify checksum if available
        if [ -f "$checksum_path" ]; then
            print_info "Verifying $image_type checksum..."
            # Handle different checksum formats
            if grep -q "SHA256" "$checksum_path" || grep -q "\.xz" "$checksum_path"; then
                # Standard SHA256 format with filename
                if ! sha256sum -c "$checksum_path" --quiet 2>/dev/null; then
                    print_warning "$image_type checksum verification failed, re-downloading..."
                    needs_redownload=true
                else
                    print_success "$image_type checksum verified"
                fi
            else
                # Try alternative verification method
                local expected_checksum=$(head -n 1 "$checksum_path" | cut -d' ' -f1)
                if [ -n "$expected_checksum" ]; then
                    local actual_checksum=$(sha256sum "$download_path" | cut -d' ' -f1)
                    if [ "$expected_checksum" = "$actual_checksum" ]; then
                        print_success "$image_type checksum verified"
                    else
                        print_warning "$image_type checksum verification failed, re-downloading..."
                        needs_redownload=true
                    fi
                else
                    print_warning "Unable to parse $image_type checksum, re-downloading..."
                    needs_redownload=true
                fi
            fi
        else
            print_warning "No $image_type checksum file found, re-downloading for safety..."
            needs_redownload=true
        fi

        # If checksum failed, clean up and re-download
        if [ "$needs_redownload" = true ]; then
            rm -f "$download_path" "$checksum_path" "$extracted_path" 2>/dev/null || true
        elif [ -f "$extracted_path" ]; then
            # If we have a valid download and extracted file, we're done
            return 0
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would download Whonix $image_type from $download_url"
        return 0
    fi

    # Download checksum first
    print_info "Downloading $image_type checksum from: $checksum_url"
    if ! wget --progress=bar:force -O "$checksum_path" "$checksum_url"; then
        print_warning "Failed to download $image_type checksum, continuing without verification"
    fi

    # Download with progress
    print_info "Downloading $image_type from: $download_url"
    if ! wget --progress=bar:force -O "$download_path" "$download_url"; then
        print_error "Failed to download Whonix $image_type"
        return 1
    fi

    # Verify checksum
    if [ -f "$checksum_path" ]; then
        print_info "Verifying $image_type checksum..."
        # Handle different checksum formats
        if grep -q "SHA256" "$checksum_path" || grep -q "\.xz" "$checksum_path"; then
            # Standard SHA256 format with filename
            if sha256sum -c "$checksum_path" --quiet 2>/dev/null; then
                print_success "$image_type checksum verified"
            else
                print_warning "$image_type checksum verification failed, but continuing..."
            fi
        else
            # Try alternative verification method
            local expected_checksum=$(head -n 1 "$checksum_path" | cut -d' ' -f1)
            if [ -n "$expected_checksum" ]; then
                local actual_checksum=$(sha256sum "$download_path" | cut -d' ' -f1)
                if [ "$expected_checksum" = "$actual_checksum" ]; then
                    print_success "$image_type checksum verified"
                else
                    print_warning "$image_type checksum verification failed, but continuing..."
                fi
            else
                print_warning "Unable to parse $image_type checksum, skipping verification"
            fi
        fi
    else
        print_warning "Skipping $image_type checksum verification"
    fi

    # Extract
    print_info "Extracting $image_type image..."
    if ! xz -d -k "$download_path"; then
        print_error "Failed to extract Whonix $image_type"
        # Clean up failed extraction
        rm -f "$extracted_path" 2>/dev/null || true
        return 1
    fi

    print_success "Whonix $image_type image downloaded and extracted"
    log_info "Downloaded Whonix $image_type to $extracted_path"
}

# =============================================================================
# VM CREATION FUNCTIONS
# =============================================================================

create_vm() {
    local vm_name="$1"
    local vm_id="$2"
    local cpu="$3"
    local ram="$4"
    local disk_size="$5"
    local bridge="$6"
    
    print_step "Creating VM: $vm_name (ID: $vm_id)..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would create VM $vm_name with ID $vm_id"
        print_info "[DRY-RUN]   CPU: $cpu, RAM: ${ram}MB, Disk: ${disk_size}GB"
        return 0
    fi
    
    # Validate VM ID is available
    if ! vm_id_available "$vm_id"; then
        print_error "VM ID $vm_id is already in use"
        return 1
    fi
    
    # Validate resources
    if [ "$cpu" -lt 1 ] || [ "$cpu" -gt 32 ]; then
        print_error "Invalid CPU count: $cpu (must be 1-32)"
        return 1
    fi
    
    if [ "$ram" -lt 256 ] || [ "$ram" -gt 65536 ]; then
        print_error "Invalid RAM amount: $ram MB (must be 256-65536)"
        return 1
    fi
    
    if [ "$disk_size" -lt 5 ] || [ "$disk_size" -gt 1000 ]; then
        print_error "Invalid disk size: $disk_size GB (must be 5-1000)"
        return 1
    fi
    
    # Create the VM
    print_info "Creating VM configuration..."
    if ! qm create $vm_id \
        --name "$vm_name" \
        --memory $ram \
        --cores $cpu \
        --bios $BIOS_TYPE \
        --ostype l26 \
        --net0 virtio,bridge=$bridge \
        --scsihw virtio-scsi-pci \
        --bootdisk scsi0 \
        --onboot $( [ "$AUTOSTART" = true ] && echo 1 || echo 0 ); then
        print_error "Failed to create VM configuration for $vm_name"
        return 1
    fi
    
    # Import disk from QCOW2
    print_info "Importing disk for $vm_name..."
    
    local disk_path=""
    if [[ "$vm_name" == *"Gateway"* ]]; then
        disk_path="/root/whonix-gateway.qcow2"
    elif [[ "$vm_name" == *"Workstation"* ]]; then
        disk_path="/root/whonix-workstation.qcow2"
    else
        print_error "Cannot determine disk type for $vm_name"
        return 1
    fi

    if [ ! -f "$disk_path" ]; then
        print_error "Whonix $vm_name disk not found at $disk_path"
        return 1
    fi

    # Import the disk
    if ! qm importdisk $vm_id "$disk_path" $STORAGE_DISK --format qcow2; then
        print_error "Failed to import disk for $vm_name"
        return 1
    fi

    # Find the imported disk name
    local disk_name=""
    for i in {0..9}; do
        if qm config $vm_id | grep -q "unused$i: ${STORAGE_DISK}:vm-${vm_id}-disk-"; then
            disk_name="unused$i"
            break
        fi
    done

    if [ -z "$disk_name" ]; then
        # Try alternative method to find disk
        local config_output=$(qm config $vm_id)
        if echo "$config_output" | grep -q "unused"; then
            disk_name=$(echo "$config_output" | grep "unused" | cut -d: -f1 | head -1)
        fi

        if [ -z "$disk_name" ]; then
            print_error "Could not find imported disk for $vm_name"
            return 1
        fi
    fi

    # Move disk from unused to scsi0
    print_info "Attaching disk to SCSI controller..."
    if ! qm move-disk $vm_id $disk_name scsi0 --delete true; then
        print_warning "Failed to move disk, trying alternative method..."
        # Alternative method: directly set the disk
        local disk_path="${STORAGE_DISK}:vm-${vm_id}-disk-0"
        if ! qm set $vm_id --scsi0 "$disk_path"; then
            print_error "Failed to attach disk to SCSI controller"
            return 1
        fi
    fi

    # Set boot order
    if ! qm set $vm_id --boot order=scsi0; then
        print_warning "Failed to set boot order, continuing..."
    fi

    print_success "VM $vm_name created successfully"
    log_info "Created VM $vm_name with ID $vm_id"
}

configure_gateway_vm() {
    local vm_id="$1"
    
    print_step "Configuring Gateway VM (ID: $vm_id)..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would configure Gateway VM $vm_id"
        print_info "[DRY-RUN]   - Add external network interface on $EXTERNAL_BRIDGE"
        return 0
    fi
    
    # Add second network interface for external connection
    print_info "Adding external network interface..."
    if ! qm set $vm_id --net1 virtio,bridge=$EXTERNAL_BRIDGE; then
        print_warning "Failed to add external network interface, continuing..."
    fi
    
    # Configure first interface for internal network
    print_info "Configuring internal network interface..."
    if ! qm set $vm_id --net0 virtio,bridge=$INTERNAL_BRIDGE; then
        print_warning "Failed to configure internal network interface, continuing..."
    fi
    
    print_success "Gateway VM configured"
}

configure_workstation_vm() {
    local vm_id="$1"
    
    print_step "Configuring Workstation VM (ID: $vm_id)..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Would configure Workstation VM $vm_id"
        return 0
    fi
    
    # Workstation only has internal network (already configured)
    # No additional configuration needed
    
    print_success "Workstation VM configured"
}

# =============================================================================
# SUMMARY FUNCTION
# =============================================================================

print_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              Whonix Deployment Complete!                         ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║  %-15s %-10s %-10s %-15s\n" "VM Name" "VM ID" "Status" "Auto-Start"
    echo "║  ────────────────────────────────────────────────────────────────  ║"
    printf "║  %-15s %-10s %-10s %-15s\n" "$GATEWAY_NAME" "$GATEWAY_VM_ID" "Stopped" "$( [ "$AUTOSTART" = true ] && echo "Yes" || echo "No" )"
    printf "║  %-15s %-10s %-10s %-15s\n" "$WORKSTATION_NAME" "$WORKSTATION_VM_ID" "Stopped" "$( [ "$AUTOSTART" = true ] && echo "Yes" || echo "No" )"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  Network Configuration:                                          ║"
    echo "║    - External Bridge: $EXTERNAL_BRIDGE (Gateway → Internet/Tor)    "
    echo "║    - Internal Bridge: $INTERNAL_BRIDGE (Gateway ↔ Workstation)     "
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  Access Instructions:                                            ║"
    echo "║    1. Gateway Console:   qm terminal $GATEWAY_VM_ID                "
    echo "║    2. Workstation Console: qm terminal $WORKSTATION_VM_ID          "
    echo "║    3. Gateway IP: 10.0.3.1 (internal) / DHCP (external)          ║"
    echo "║    4. Workstation IP: 10.0.3.2 (internal only)                   ║"
    echo "║    5. All Workstation traffic is routed through Tor              ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  Next Steps:                                                     ║"
    echo "║    - Start the Gateway VM first                                  ║"
    echo "║    - Wait 2-3 minutes for Whonix services to initialize          ║"
    echo "║    - Gateway will automatically connect to Tor network           ║"
    echo "║    - Start Workstation VM after Gateway is fully booted          ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --iso-storage)
                STORAGE_ISO="$2"
                shift 2
                ;;
            --disk-storage)
                STORAGE_DISK="$2"
                shift 2
                ;;
            --gateway-cpu)
                GATEWAY_CPU="$2"
                shift 2
                ;;
            --gateway-ram)
                GATEWAY_RAM="$2"
                shift 2
                ;;
            --workstation-cpu)
                WORKSTATION_CPU="$2"
                shift 2
                ;;
            --workstation-ram)
                WORKSTATION_RAM="$2"
                shift 2
                ;;
            --gateway-disk)
                GATEWAY_DISK_SIZE="$2"
                shift 2
                ;;
            --workstation-disk)
                WORKSTATION_DISK_SIZE="$2"
                shift 2
                ;;
            --gateway-name)
                GATEWAY_NAME="$2"
                shift 2
                ;;
            --workstation-name)
                WORKSTATION_NAME="$2"
                shift 2
                ;;
            --gateway-id)
                GATEWAY_VM_ID="$2"
                shift 2
                ;;
            --workstation-id)
                WORKSTATION_VM_ID="$2"
                shift 2
                ;;
            --external-bridge)
                EXTERNAL_BRIDGE="$2"
                shift 2
                ;;
            --internal-bridge)
                INTERNAL_BRIDGE="$2"
                shift 2
                ;;
            --no-autostart)
                AUTOSTART=false
                shift
                ;;
            --no-bridge)
                CREATE_INTERNAL_BRIDGE=false
                shift
                ;;
            --yes)
                SKIP_CONFIRM=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            --version)
                echo "Whonix Proxmox Setup Script v$VERSION"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Automated deployment of Whonix Gateway and Workstation VMs on Proxmox VE.

Options:
  --iso-storage NAME      Storage for ISO files (default: local)
  --disk-storage NAME     Storage for VM disks (default: local-lvm)
  --gateway-cpu N         Gateway CPU cores (default: 1)
  --gateway-ram N         Gateway RAM in MB (default: 512)
  --workstation-cpu N     Workstation CPU cores (default: 2)
  --workstation-ram N     Workstation RAM in MB (default: 2048)
  --gateway-disk N        Gateway disk size in GB (default: 10)
  --workstation-disk N    Workstation disk size in GB (default: 20)
  --gateway-name NAME     Gateway VM name (default: Whonix-Gateway)
  --workstation-name NAME Workstation VM name (default: Whonix-Workstation)
  --gateway-id N          Gateway VM ID (default: auto-assign)
  --workstation-id N      Workstation VM ID (default: auto-assign)
  --external-bridge NAME  External bridge name (default: vmbr0)
  --internal-bridge NAME  Internal bridge name (default: vmbr1)
  --no-autostart          Disable auto-start on boot
  --no-bridge             Don't create internal bridge
  --yes                   Skip confirmation prompts
  --dry-run               Show what would be done without executing
  --help                  Show this help message
  --version               Show version information

Examples:
  $SCRIPT_NAME --yes                          # Run with defaults, no prompts
  $SCRIPT_NAME --gateway-ram 1024 --yes       # Custom RAM, no prompts
  $SCRIPT_NAME --dry-run                      # Preview changes
  $SCRIPT_NAME --iso-storage nvme --yes       # Custom storage

EOF
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    parse_args "$@"
    
    print_colored "$CYAN" "
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║        Whonix Proxmox Setup Script v$VERSION                     ║
║                                                              ║
║   Automated Whonix Gateway & Workstation Deployment          ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
"
    
    log_info "Starting Whonix setup script"
    
    # Check prerequisites
    check_prerequisites || exit 1
    
    # Select storage
    select_storage
    
    # Create internal bridge
    create_internal_bridge
    
    # Download Whonix images
    download_whonix_images
    
    # Validate or get VM IDs
    if [ -n "$GATEWAY_VM_ID" ]; then
        if ! validate_vm_id "$GATEWAY_VM_ID" "$GATEWAY_NAME"; then
            exit 1
        fi
    else
        GATEWAY_VM_ID=$(get_next_vm_id)
        # Validate the auto-assigned ID
        if ! validate_vm_id "$GATEWAY_VM_ID" "$GATEWAY_NAME"; then
            exit 1
        fi
    fi
    
    if [ -n "$WORKSTATION_VM_ID" ]; then
        if ! validate_vm_id "$WORKSTATION_VM_ID" "$WORKSTATION_NAME"; then
            exit 1
        fi
    else
        # Get next ID after gateway
        WORKSTATION_VM_ID=$(get_next_vm_id)
        # Ensure it's different from gateway
        if [ "$WORKSTATION_VM_ID" = "$GATEWAY_VM_ID" ]; then
            WORKSTATION_VM_ID=$((WORKSTATION_VM_ID + 1))
        fi
        # Validate the auto-assigned ID
        if ! validate_vm_id "$WORKSTATION_VM_ID" "$WORKSTATION_NAME"; then
            exit 1
        fi
    fi
    
    # Confirm configuration
    if [ "$SKIP_CONFIRM" = false ]; then
        echo ""
        print_info "Configuration Summary:"
        echo "  Gateway VM:    $GATEWAY_NAME (ID: $GATEWAY_VM_ID)"
        echo "    - CPU: $GATEWAY_CPU, RAM: ${GATEWAY_RAM}MB, Disk: ${GATEWAY_DISK_SIZE}GB"
        echo "  Workstation VM: $WORKSTATION_NAME (ID: $WORKSTATION_VM_ID)"
        echo "    - CPU: $WORKSTATION_CPU, RAM: ${WORKSTATION_RAM}MB, Disk: ${WORKSTATION_DISK_SIZE}GB"
        echo "  Storage: ISO=$STORAGE_ISO, Disk=$STORAGE_DISK"
        echo "  Network: External=$EXTERNAL_BRIDGE, Internal=$INTERNAL_BRIDGE"
        echo ""
        confirm "Proceed with deployment?" || exit 0
    fi
    
    # Create Gateway VM
    create_vm "$GATEWAY_NAME" "$GATEWAY_VM_ID" "$GATEWAY_CPU" "$GATEWAY_RAM" "$GATEWAY_DISK_SIZE" "$INTERNAL_BRIDGE"
    configure_gateway_vm "$GATEWAY_VM_ID"
    
    # Create Workstation VM
    create_vm "$WORKSTATION_NAME" "$WORKSTATION_VM_ID" "$WORKSTATION_CPU" "$WORKSTATION_RAM" "$WORKSTATION_DISK_SIZE" "$INTERNAL_BRIDGE"
    configure_workstation_vm "$WORKSTATION_VM_ID"
    
    # Print summary
    print_summary
    
    log_info "Whonix setup completed successfully"
}

# Cleanup function
clean_temp_files() {
    # Handle cases where function might be called with unexpected parameters
    local force=""
    if [ $# -gt 0 ]; then
        force="${1:-}"
    fi
    
    if [ "$force" != "force" ] && [ "$DRY_RUN" = true ]; then
        return 0
    fi
    
    print_info "Cleaning up temporary files..."
    rm -f /root/whonix.ova.xz /root/whonix.ova /root/whonix.sha256 2>/dev/null || true
    print_success "Temporary files cleaned up"
}

# Call cleanup on exit
trap clean_temp_files EXIT

# Run main function
main "$@"
