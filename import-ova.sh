#!/bin/bash

# Foundry Appliance OVA Import Script
# Imports a processed Foundry appliance OVA into ESXi/vSphere
#
# Usage: ./import-ova.sh <ova_file> [vm_name] [resource_pool]
#   ova_file: Path to the OVA file to import (required)
#   vm_name: Name for the VM (optional, defaults to foundry-appliance-<version>)
#   resource_pool: vSphere resource pool (optional, defaults to Resources)
#
# Options:
#   -f, --force: Remove existing VM if it exists
#   -a, --auto-rename: Automatically generate unique name if VM exists
#
# Environment variables:
#   GOVC_URL: ESXi host or vCenter server (required)
#   GOVC_USERNAME: Username (defaults to 'root')
#   GOVC_PASSWORD: Password (required)
#   GOVC_DATASTORE: Target datastore (defaults to 'datastore1')
#   GOVC_INSECURE: Skip SSL verification (defaults to '1')

set -e  # Exit on any error

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect OS for govc installation
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unsupported"
    fi
}

# Function to install govc
install_govc() {
    local os=$(detect_os)
    echo "Installing govc..."
    
    if [ "$os" = "macos" ]; then
        if command_exists brew; then
            echo "Using Homebrew to install govc..."
            brew install govc
            return
        fi
        
        local arch=$(uname -m)
        case "$arch" in
            x86_64) arch="amd64" ;;
            arm64) arch="arm64" ;;
            *) 
                echo "Unsupported macOS architecture: $arch"
                exit 1
                ;;
        esac
        
        curl -L "https://github.com/vmware/govmomi/releases/latest/download/govc_Darwin_${arch}.tar.gz" | tar -xz
        chmod +x govc
        sudo mv govc /usr/local/bin/govc
        
    elif [ "$os" = "linux" ]; then
        local arch=$(uname -m)
        case "$arch" in
            x86_64) arch="amd64" ;;
            aarch64|arm64) arch="arm64" ;;
            *) 
                echo "Unsupported Linux architecture: $arch"
                exit 1
                ;;
        esac
        
        curl -L "https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_${arch}.tar.gz" | tar -xz
        chmod +x govc
        sudo mv govc /usr/local/bin/govc
        
    else
        echo "Unsupported OS for govc installation"
        exit 1
    fi
}

# Parse arguments
FORCE_REPLACE=false
AUTO_RENAME=false
ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE_REPLACE=true
            shift
            ;;
        -a|--auto-rename)
            AUTO_RENAME=true
            shift
            ;;
        -h|--help)
            echo "Foundry Appliance OVA Import Script"
            echo ""
            echo "Usage: $0 [options] <ova_file> [vm_name] [resource_pool]"
            echo ""
            echo "Options:"
            echo "  -f, --force        Remove existing VM if it exists"
            echo "  -a, --auto-rename  Automatically generate unique name if VM exists"
            echo "  -h, --help         Show this help message"
            echo ""
            echo "Example:"
            echo "  export GOVC_URL=esx-01.example.com"
            echo "  export GOVC_USERNAME=root"
            echo "  export GOVC_PASSWORD='password123'"
            echo "  export GOVC_DATASTORE=datastore1"
            echo "  ./import-ova.sh -f output/foundry-appliance-v0.10.2.ova"
            echo ""
            echo "Environment variables:"
            echo "  GOVC_URL: ESXi host or vCenter server (required)"
            echo "  GOVC_USERNAME: Username (defaults to 'root')"
            echo "  GOVC_PASSWORD: Password (required)"
            echo "  GOVC_DATASTORE: Target datastore (defaults to 'datastore1')"
            echo "  GOVC_INSECURE: Skip SSL verification (defaults to '1')"
            exit 0
            ;;
        -*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Check arguments
if [ ${#ARGS[@]} -lt 1 ]; then
    echo "Error: OVA file path is required"
    echo ""
    echo "Usage: $0 [options] <ova_file> [vm_name] [resource_pool]"
    echo ""
    echo "Use -h or --help for detailed help"
    exit 1
fi

OVA_FILE="${ARGS[0]}"

# Convert to absolute path
if [[ "$OVA_FILE" != /* ]]; then
    OVA_FILE="$(pwd)/$OVA_FILE"
fi

# Validate OVA file exists
if [ ! -f "$OVA_FILE" ]; then
    echo "Error: OVA file not found: $OVA_FILE"
    echo ""
    echo "Make sure you've run download-ova.sh first to create the processed OVA."
    exit 1
fi

# Set defaults and parse arguments
GOVC_USERNAME=${GOVC_USERNAME:-'root'}
GOVC_DATASTORE=${GOVC_DATASTORE:-'datastore1'}
GOVC_INSECURE=${GOVC_INSECURE:-'1'}

# Extract version from OVA filename for VM naming
OVA_FILENAME=$(basename "$OVA_FILE")
if echo "$OVA_FILENAME" | grep -q "v[0-9]"; then
    VERSION=$(echo "$OVA_FILENAME" | grep -o "v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" | head -1)
    DEFAULT_VM_NAME="foundry-appliance-${VERSION}"
else
    DEFAULT_VM_NAME="foundry-appliance"
fi

GOVC_VM_NAME=${ARGS[1]:-${GOVC_VM_NAME:-$DEFAULT_VM_NAME}}
GOVC_RESOURCE_POOL=${ARGS[2]:-${GOVC_RESOURCE_POOL:-'Resources'}}

# Validate required parameters
if [[ -z "$GOVC_URL" || -z "$GOVC_PASSWORD" ]]; then
    echo "Error: Missing required credentials"
    echo ""
    echo "Set the following environment variables:"
    echo "  export GOVC_URL=<esxi-host-or-vcenter>"
    echo "  export GOVC_PASSWORD='<password>'"
    echo ""
    echo "Optional:"
    echo "  export GOVC_USERNAME=root              # defaults to 'root'"
    echo "  export GOVC_DATASTORE=datastore1       # defaults to 'datastore1'"
    echo "  export GOVC_INSECURE=1                 # defaults to '1'"
    exit 1
fi

# Check and install govc
echo "Checking for required applications..."
if ! command_exists govc; then
    echo "govc not found, installing..."
    install_govc
else
    echo "govc found"
fi

# Export credentials for govc
export GOVC_URL
export GOVC_USERNAME
export GOVC_PASSWORD
export GOVC_INSECURE

echo ""
echo "Import Configuration:"
echo "  ESXi/vCenter: $GOVC_URL"
echo "  Username: $GOVC_USERNAME"
echo "  Datastore: $GOVC_DATASTORE"
echo "  VM Name: $GOVC_VM_NAME"
echo "  Resource Pool: $GOVC_RESOURCE_POOL"
echo "  OVA File: $OVA_FILE"
echo ""

# Validate connection
echo "Validating ESXi/vCenter connection..."
if ! govc about >/dev/null 2>&1; then
    echo "Error: Failed to connect to ESXi/vCenter"
    echo "Please verify:"
    echo "  - GOVC_URL is correct and reachable"
    echo "  - GOVC_USERNAME and GOVC_PASSWORD are valid"
    echo "  - Host is accessible on the network"
    exit 1
fi

echo "✓ Successfully connected to $(govc about -json | grep -o '"Name":"[^"]*' | cut -d'"' -f4)"

# Function to check if VM exists
vm_exists() {
    local vm_name="$1"
    govc find . -type m -name "$vm_name" | grep -q "/"
}

# Function to generate unique VM name
generate_unique_vm_name() {
    local base_name="$1"
    local counter=1
    local test_name="$base_name"
    
    while vm_exists "$test_name"; do
        test_name="${base_name}-${counter}"
        counter=$((counter + 1))
    done
    
    echo "$test_name"
}

# Function to remove existing VM
remove_existing_vm() {
    local vm_name="$1"
    echo "Removing existing VM '$vm_name'..."
    
    # Get VM path for operations
    local vm_path=$(govc find . -type m -name "$vm_name")
    if [ -z "$vm_path" ]; then
        echo "Error: VM '$vm_name' not found"
        return 1
    fi
    
    # Power off VM if it's running
    if govc vm.info "$vm_name" | grep -q "powerState:.*poweredOn"; then
        echo "Powering off VM..."
        govc vm.power -off "$vm_name" || true
        sleep 2
    fi
    
    # Destroy the VM
    if govc vm.destroy "$vm_name"; then
        echo "✓ Existing VM removed successfully"
        return 0
    else
        echo "Error: Failed to remove existing VM"
        return 1
    fi
}

# Check if VM already exists and handle accordingly
if vm_exists "$GOVC_VM_NAME"; then
    echo ""
    echo "Warning: VM '$GOVC_VM_NAME' already exists"
    
    if [ "$FORCE_REPLACE" = true ]; then
        echo "Force replace option enabled, removing existing VM..."
        if ! remove_existing_vm "$GOVC_VM_NAME"; then
            echo "Failed to remove existing VM. Aborting import."
            exit 1
        fi
    elif [ "$AUTO_RENAME" = true ]; then
        echo "Auto-rename option enabled, generating unique name..."
        ORIGINAL_NAME="$GOVC_VM_NAME"
        GOVC_VM_NAME=$(generate_unique_vm_name "$GOVC_VM_NAME")
        echo "Using new VM name: $GOVC_VM_NAME (original: $ORIGINAL_NAME)"
    else
        echo "Please choose one of the following options:"
        echo ""
        echo "1. Use --force (-f) to replace the existing VM:"
        echo "   $0 --force \"$OVA_FILE\""
        echo ""
        echo "2. Use --auto-rename (-a) to automatically generate a unique name:"
        echo "   $0 --auto-rename \"$OVA_FILE\""
        echo ""
        echo "3. Specify a different VM name:"
        echo "   $0 \"$OVA_FILE\" \"my-custom-name\""
        echo ""
        echo "4. Manually remove the existing VM:"
        echo "   govc vm.power -off '$GOVC_VM_NAME'"
        echo "   govc vm.destroy '$GOVC_VM_NAME'"
        exit 1
    fi
fi

# Extract OVF from OVA for import
TEMP_DIR=$(mktemp -d)
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "Extracting OVF from OVA..."
cd "$TEMP_DIR"
tar -xf "$OVA_FILE"

# Find the OVF file
OVF_FILE=""
for file in *.ovf; do
    if [ -f "$file" ]; then
        OVF_FILE="$file"
        break
    fi
done

if [ -z "$OVF_FILE" ]; then
    echo "Error: No OVF file found in the OVA"
    exit 1
fi

echo "Found OVF file: $OVF_FILE"

# Import the OVF
echo ""
echo "Starting VM import..."
echo "This may take several minutes depending on the VM size..."

if govc import.ovf \
    -ds="$GOVC_DATASTORE" \
    -name="$GOVC_VM_NAME" \
    -pool="$GOVC_RESOURCE_POOL" \
    "$OVF_FILE"; then
    
    echo "✓ VM imported successfully"
    
    # Power on the VM
    echo "Powering on VM..."
    if govc vm.power -on "$GOVC_VM_NAME"; then
        echo "✓ VM powered on successfully"
    else
        echo "Warning: Failed to power on VM. You can power it on manually."
    fi
    
    echo ""
    echo "VM Information:"
    govc vm.info "$GOVC_VM_NAME"
    
    echo ""
    echo "✓ Import completed successfully!"
    echo "VM '$GOVC_VM_NAME' is now available on $GOVC_URL"
    
else
    echo "Error: Failed to import OVA"
    echo ""
    echo "Common issues:"
    echo "  - Insufficient storage space on datastore"
    echo "  - ESXi license restrictions (free license may not support OVA import)"
    echo "  - Network connectivity issues"
    echo "  - Invalid OVF format"
    echo ""
    echo "For ESXi free license users:"
    echo "  Use the ESXi web interface to manually import the OVA file"
    exit 1
fi