#!/bin/bash

# Universal Foundry Appliance Import Script
# Works on: macOS, Linux, ESXi hosts, and via curl piping
#
# Usage options:
# 1) Local with env vars: export GOVC_URL=<server> GOVC_PASSWORD=<password> && ./import-appliance.sh [username] [datastore] [vm_name] [resource_pool]
# 2) Local with args: ./import-appliance.sh <GOVC_URL> <GOVC_PASSWORD> [username] [datastore] [vm_name] [resource_pool]
# 3) Via curl: curl -sSL <script-url> | bash -s -- <GOVC_URL> <GOVC_PASSWORD> [username] [datastore] [vm_name] [resource_pool]
# 4) On ESXi: Same as options 2 or 3, automatically detects ESXi environment

set -e  # Exit on any error

# Detect environment
detect_environment() {
    # Check if we're on ESXi
    if [ -f /etc/vmware-release ] && grep -q "ESXi" /etc/vmware-release 2>/dev/null; then
        echo "esxi"
    elif [ -f /etc/vmware-release ]; then
        echo "vmware"  
    elif command -v uname >/dev/null 2>&1; then
        case "$(uname -s)" in
            Darwin) echo "macos" ;;
            Linux) echo "linux" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

PLATFORM=$(detect_environment)
echo "Detected platform: $PLATFORM"

# Use sh for ESXi compatibility, bash for others
if [ "$PLATFORM" = "esxi" ]; then
    # Ensure we're using sh syntax
    set +h  # Disable hash table for commands
fi

# Check if credentials are provided as arguments (for curl usage) or environment variables
if [[ $# -ge 2 ]]; then
    # Arguments provided - assume curl usage format
    GOVC_URL="$1"
    GOVC_PASSWORD="$2"
    shift 2  # Remove first two arguments
else
    # No arguments - check environment variables
    if [[ -z "$GOVC_URL" || -z "$GOVC_PASSWORD" ]]; then
        echo "Error: Missing required credentials"
        echo ""
        echo "For curl usage:"
        echo "  curl -sSL <script-url> | bash -s -- <GOVC_URL> <GOVC_PASSWORD> [username] [datastore] [vm_name] [resource_pool]"
        echo ""
        echo "Example:"
        echo "  curl -sSL https://raw.githubusercontent.com/sei-noconnor/foundry-appliance/main/import-appliance.sh | bash -s -- esx-01.example.com 'password123'"
        echo ""
        echo "For local execution:"
        echo "  export GOVC_URL=<ESXi-server-or-vcenter>"
        echo "  export GOVC_PASSWORD='<password>'"
        echo "  ./import-appliance.sh [username] [datastore] [vm_name] [resource_pool]"
        echo ""
        echo "Optional parameters:"
        echo "  GOVC_USERNAME (default: 'root')"
        echo "  GOVC_DATASTORE (default: 'ds_nfs')"
        echo "  GOVC_VM_NAME (default: 'foundry-appliance')"
        echo "  GOVC_RESOURCE_POOL (default: 'Resources')"
        exit 1
    fi
fi

# Create temporary working directory (platform-aware)
if [ "$PLATFORM" = "esxi" ]; then
    # ESXi has limited space, use /tmp with process ID
    TEMP_DIR="/tmp/foundry-import-$$"
    mkdir -p "$TEMP_DIR"
else
    # Use mktemp for other platforms
    TEMP_DIR=$(mktemp -d)
fi

echo "Working in temporary directory: $TEMP_DIR"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Function to check if command exists (cross-platform)
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Detect download tool
detect_download_tool() {
    if command_exists curl; then
        echo "curl"
    elif command_exists wget; then
        echo "wget"
    else
        echo "none"
    fi
}

# Universal download function
download_file() {
    local url="$1"
    local output="$2"
    local tool=$(detect_download_tool)
    
    case "$tool" in
        curl)
            curl -L -o "$output" "$url"
            ;;
        wget)
            wget -O "$output" "$url"
            ;;
        none)
            echo "Error: Neither curl nor wget found for downloading files"
            exit 1
            ;;
    esac
}

# Function to detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unsupported"
    fi
}

# Function to install xmllint
install_xmllint() {
    local os=$(detect_os)
    echo "Installing xmllint..."
    
    if [[ "$os" == "macos" ]]; then
        if command_exists brew; then
            brew install libxml2
        else
            echo "Please install Homebrew or libxml2 manually"
            exit 1
        fi
    elif [[ "$os" == "linux" ]]; then
        if command_exists apt-get; then
            sudo apt-get update && sudo apt-get install -y libxml2-utils
        elif command_exists yum; then
            sudo yum install -y libxml2
        elif command_exists dnf; then
            sudo dnf install -y libxml2
        else
            echo "Please install libxml2-utils manually"
            exit 1
        fi
    else
        echo "Unsupported OS for xmllint installation"
        exit 1
    fi
}

# Function to download and install govc
install_govc() {
    local os=$(detect_os)
    echo "Installing govc..."
    
    if [ "$PLATFORM" = "esxi" ]; then
        # For ESXi, install to temp directory (no sudo available)
        echo "Installing govc to temporary directory for ESXi..."
        cd "$TEMP_DIR"
        download_file "https://github.com/vmware/govmomi/releases/latest/download/govc_linux_amd64.gz" "govc.gz"
        gunzip govc.gz
        chmod +x govc
        GOVC_PATH="$TEMP_DIR/govc"
        echo "govc installed to $GOVC_PATH"
        cd - > /dev/null
    elif [ "$os" = "macos" ]; then
        download_file "https://github.com/vmware/govmomi/releases/latest/download/govc_darwin_amd64.gz" "govc_darwin_amd64.gz"
        gunzip govc_darwin_amd64.gz
        chmod +x govc_darwin_amd64
        sudo mv govc_darwin_amd64 /usr/local/bin/govc
        GOVC_PATH="govc"
    elif [ "$os" = "linux" ]; then
        download_file "https://github.com/vmware/govmomi/releases/latest/download/govc_linux_amd64.gz" "govc_linux_amd64.gz"
        gunzip govc_linux_amd64.gz
        chmod +x govc_linux_amd64
        sudo mv govc_linux_amd64 /usr/local/bin/govc
        GOVC_PATH="govc"
    else
        echo "Unsupported OS for govc installation"
        exit 1
    fi
}

# Check and install required applications
echo "Checking for required applications..."

# Initialize GOVC_PATH
GOVC_PATH="govc"

# Platform-specific requirements
if [ "$PLATFORM" = "esxi" ]; then
    echo "ESXi platform detected - checking for basic tools..."
    if ! command_exists tar; then
        echo "Error: tar not found. This script requires tar for OVA extraction."
        exit 1
    fi
    if [ "$(detect_download_tool)" = "none" ]; then
        echo "Error: Neither curl nor wget found for downloading files."
        exit 1
    fi
    echo "Basic tools found: tar, $(detect_download_tool)"
else
    # For non-ESXi platforms, check for xmllint
    if ! command_exists xmllint; then
        echo "xmllint not found, installing..."
        install_xmllint
    else
        echo "xmllint found"
    fi
fi

# Check for govc on all platforms
if ! command_exists govc; then
    echo "govc not found, installing..."
    install_govc
else
    echo "govc found in PATH"
    GOVC_PATH="govc"
fi

echo "All required applications are available"
echo ""

# 1) Download and extract the OVA
cd "$TEMP_DIR"

echo "Downloading foundry.ova..."
echo "This may take several minutes depending on your connection..."
download_file "https://incuspub.blob.core.usgovcloudapi.net/ova/appliance/foundry-appliance-v0.10.2.ova" "foundry.ova"

if [ ! -f foundry.ova ]; then
    echo "Error: Failed to download foundry.ova"
    exit 1
fi

echo "Download completed. File size: $(ls -lh foundry.ova | awk '{print $5}')"

echo "Extracting OVA..."
mkdir foundry-ova
# OVA files are TAR archives, but may need special handling
if tar -tf foundry.ova >/dev/null 2>&1; then
    tar -C foundry-ova -xf foundry.ova
else
    echo "Error: foundry.ova appears to be corrupted or not a valid OVA file"
    echo "Please re-download the OVA file"
    exit 1
fi

# 2) Remove any <Item> with <rasd:ResourceType>35</rasd:ResourceType> (sound card)
cd foundry-ova

# Find the OVF file
OVF_FILE=""
for file in *.ovf; do
    if [ -f "$file" ]; then
        OVF_FILE="$file"
        break
    fi
done

if [ -z "$OVF_FILE" ]; then
    echo "Error: No OVF file found in the extracted OVA"
    exit 1
fi

echo "Processing $OVF_FILE to remove sound card..."

if [ "$PLATFORM" = "esxi" ] || ! command_exists python3; then
    # Use sed-based approach for ESXi or systems without Python
    echo "Using simplified sound card removal (sed-based)..."
    
    # Create a backup
    cp "$OVF_FILE" "${OVF_FILE}.backup"
    
    # Use sed to remove sound card entries (ResourceType 35)
    # This removes entire Item blocks containing ResourceType 35
    sed -i.tmp '/ResourceType>35<\/rasd:ResourceType>/,/<\/Item>/d' "$OVF_FILE" 2>/dev/null || {
        echo "Warning: Could not remove sound card automatically. Proceeding with original OVF."
        cp "${OVF_FILE}.backup" "$OVF_FILE"
    }
    rm -f "${OVF_FILE}.tmp" 2>/dev/null
    echo "Sound card removal completed (simplified method)"
else
    # Use Python for more precise XML editing on systems that have it
    echo "Using Python for precise sound card removal..."
    python3 -c "
import xml.etree.ElementTree as ET
import glob
import sys

for ovf_file in glob.glob('*.ovf'):
    try:
        # Parse the XML file
        tree = ET.parse(ovf_file)
        root = tree.getroot()
        
        # Find all Item elements that contain ResourceType 35
        items_removed = 0
        for parent in root.iter():
            items_to_remove = []
            for child in list(parent):
                if child.tag.endswith('Item'):
                    # Look for ResourceType child with value 35
                    for subchild in child:
                        if subchild.tag.endswith('ResourceType') and subchild.text == '35':
                            items_to_remove.append(child)
                            break
            
            # Remove the items
            for item in items_to_remove:
                parent.remove(item)
                items_removed += 1
                print(f'Removed sound card item (ResourceType 35)')
        
        # Write back the modified XML
        ET.register_namespace('', 'http://schemas.dmtf.org/ovf/envelope/1')
        ET.register_namespace('rasd', 'http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData')
        ET.register_namespace('vssd', 'http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData')
        
        with open(ovf_file, 'wb') as f:
            tree.write(f, encoding='utf-8', xml_declaration=True)
        print(f'Processed {ovf_file} - removed {items_removed} sound card items')
        
    except Exception as e:
        print(f'Error processing {ovf_file}: {e}', file=sys.stderr)
        sys.exit(1)
"
fi

# Update the manifest file with new checksums
if [ -f "$OVF_FILE" ]; then
    echo "Updating manifest file..."
    
    # Calculate hash (try different methods)
    if command_exists sha256sum; then
        ovf_hash=$(sha256sum "$OVF_FILE" | cut -d' ' -f1)
    elif command_exists openssl; then
        ovf_hash=$(openssl sha256 "$OVF_FILE" | cut -d' ' -f2)
    else
        echo "Warning: No SHA256 tool found, skipping manifest update"
        ovf_hash=""
    fi
    
    if [ -n "$ovf_hash" ]; then
        mf_file="${OVF_FILE%.ovf}.mf"
        if [ -f "$mf_file" ]; then
            # Create backup and update manifest
            cp "$mf_file" "${mf_file}.backup"
            sed -i.tmp "s/SHA256(${OVF_FILE})=.*/SHA256(${OVF_FILE})= ${ovf_hash}/" "$mf_file" 2>/dev/null || {
                echo "SHA256(${OVF_FILE})= ${ovf_hash}" > "$mf_file"
            }
            rm -f "${mf_file}.tmp" 2>/dev/null
            echo "Updated manifest for $OVF_FILE"
        fi
    fi
fi

cd "$TEMP_DIR"

echo ""
echo "OVA processing completed successfully"

# 3) Import the edited OVF with govc
# Parse remaining command line arguments or use environment variables (with defaults)
# Note: $1, $2, etc. now refer to remaining args after URL/password were shifted off
GOVC_USERNAME=${1:-${GOVC_USERNAME:-'root'}}
GOVC_DATASTORE=${2:-${GOVC_DATASTORE:-'ds_nfs'}}
GOVC_VM_NAME=${3:-${GOVC_VM_NAME:-'foundry-appliance'}}
GOVC_RESOURCE_POOL=${4:-${GOVC_RESOURCE_POOL:-'Resources'}}

# Export for govc
export GOVC_URL
export GOVC_USERNAME
export GOVC_PASSWORD
export GOVC_INSECURE=1

echo ""
echo "Starting VM import..."
echo "Connecting to vSphere at $GOVC_URL as $GOVC_USERNAME..."

echo "Importing OVF..."
"$GOVC_PATH" import.ovf \
  -ds="$GOVC_DATASTORE" \
  -name="$GOVC_VM_NAME" \
  -pool="$GOVC_RESOURCE_POOL" \
  "foundry-ova/$OVF_FILE"

# 4) Power on and verify
echo "Powering on VM..."
"$GOVC_PATH" vm.power -on "$GOVC_VM_NAME"

echo ""
echo "VM Information:"
"$GOVC_PATH" vm.info "$GOVC_VM_NAME"

echo ""
echo "Import completed successfully!"
echo "VM '$GOVC_VM_NAME' has been imported and powered on."
