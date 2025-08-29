#!/bin/bash

# Foundry Appliance Import Script
# Works on: macOS and Linux hosts
# Note: ESXi hosts are not supported due to wget lacking HTTPS support
#
# Usage options:
# 1) Local: export GOVC_URL=<server> GOVC_PASSWORD=<password> GOVC_DATASTORE=<datastore> && ./import-appliance.sh
# 2) Via curl: curl -sSL <script-url> | GOVC_URL=<server> GOVC_PASSWORD=<password> GOVC_DATASTORE=<datastore> bash

set -e  # Exit on any error

# Check for ESXi and exit with error
if [ -f /etc/vmware-release ] && grep -q "ESXi" /etc/vmware-release 2>/dev/null; then
    echo "Error: ESXi hosts are not supported"
    echo "ESXi's built-in wget does not support HTTPS, which is required for downloading"
    echo "Please run this script from a Linux or macOS host with network access to your ESXi server"
    exit 1
fi

# Function to get latest release URL from GitHub API
get_latest_release_url() {
    local tool=$(detect_download_tool)
    local api_url="https://api.github.com/repos/cmu-sei/foundry-appliance/releases/latest"
    local temp_response="${TEMP_DIR}/github_response.json"
    local fallback_url="https://incuspub.blob.core.usgovcloudapi.net/ova/appliance/foundry-appliance-v0.10.2.ova"
    
    case "$tool" in
        curl)
            if curl -s "$api_url" > "$temp_response" 2>/dev/null && [ -s "$temp_response" ]; then
                # File exists and is not empty
                :
            else
                echo "$fallback_url"
                return
            fi
            ;;
        wget)
            if wget -q -O "$temp_response" "$api_url" 2>/dev/null && [ -s "$temp_response" ]; then
                # File exists and is not empty
                :
            else
                echo "$fallback_url"
                return
            fi
            ;;
        *)
            echo "$fallback_url"
            return
            ;;
    esac
    
    # Extract OVA URL from JSON response
    if [ -f "$temp_response" ] && grep -q "browser_download_url" "$temp_response" 2>/dev/null; then
        # Try to extract the .ova URL
        if command_exists grep && command_exists sed; then
            ova_url=$(grep "browser_download_url.*\.ova" "$temp_response" 2>/dev/null | head -1 | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' 2>/dev/null)
            if [ -n "$ova_url" ] && [ "$ova_url" != "$temp_response" ]; then
                rm -f "$temp_response" 2>/dev/null
                echo "$ova_url"
                return
            fi
        fi
    fi
    
    # Fallback to hardcoded URL if API parsing fails
    rm -f "$temp_response" 2>/dev/null
    echo "$fallback_url"
}

# Check for required environment variables
if [[ -z "$GOVC_URL" || -z "$GOVC_PASSWORD" ]]; then
        echo "Error: Missing required credentials"
        echo ""
        echo "For curl usage:"
        echo "  curl -sSL <script-url> | GOVC_URL=<host> GOVC_USERNAME=root GOVC_PASSWORD='<pass>' GOVC_DATASTORE=<datastore> bash"
        echo ""
        echo "For local execution:"
        echo "  export GOVC_URL=<ESXi-server-or-vcenter>"
        echo "  export GOVC_USERNAME=root"
        echo "  export GOVC_PASSWORD='<password>'"
        echo "  export GOVC_DATASTORE=<datastore>"
        echo "  ./import-appliance.sh"
        exit 1
fi

# Create or reuse working directory (avoid tmpfs space limits)
if [ -d "$HOME" ] && [ -w "$HOME" ]; then
    TEMP_DIR="$HOME/.foundry-appliance-import"
else
    TEMP_DIR="/var/tmp/foundry-appliance-import"
fi
mkdir -p "$TEMP_DIR"

echo "Working in temporary directory: $TEMP_DIR"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    # Only clean extracted files, keep downloaded OVA for reuse
    rm -rf "$TEMP_DIR"/foundry-ova 2>/dev/null || true
    rm -f "$TEMP_DIR"/github_response.json 2>/dev/null || true
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
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) echo "linux" ;;
        *) echo "unsupported" ;;
    esac
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

# Function to get latest govc version from GitHub
get_latest_govc_version() {
    local tool=$(detect_download_tool)
    local api_url="https://api.github.com/repos/vmware/govmomi/releases/latest"
    
    echo "Fetching latest govc version from GitHub API..." >&2
    
    case "$tool" in
        curl)
            # Get the tag_name from the latest release API
            local version=$(curl -s "$api_url" 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null)
            echo "API returned version: $version" >&2
            echo "$version"
            ;;
        wget)
            # Fallback: try to get version from redirect
            local version=$(wget -qO- "$api_url" 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' 2>/dev/null)
            echo "API returned version: $version" >&2
            echo "$version"
            ;;
        *)
            echo "No download tool available, using fallback version" >&2
            echo "v0.52.0"  # fallback version
            ;;
    esac
}

# Function to download and install govc
install_govc() {
    local os=$(detect_os)
    echo "Installing govc..."
    
    if [ "$os" = "macos" ]; then
        # Check for Homebrew first
        if command_exists brew; then
            echo "Using Homebrew to install govc..."
            brew install govc
            GOVC_PATH="govc"
            return
        fi
        
        # Manual installation for macOS
        echo "Homebrew not found, installing from GitHub releases..."
        local arch=$(uname -m)
        case "$arch" in
            x86_64) arch="x86_64" ;;
            arm64) arch="arm64" ;;
            *) 
                echo "Unsupported macOS architecture: $arch"
                exit 1
                ;;
        esac
        
        local version=$(get_latest_govc_version)
        if [ -z "$version" ]; then
            version="v0.52.0"  # fallback
        fi
        echo "Installing govc version: $version"
        
        local download_url="https://github.com/vmware/govmomi/releases/download/${version}/govc_Darwin_${arch}.tar.gz"
        echo "Downloading from: $download_url"
        download_file "$download_url" "govc_Darwin_${arch}.tar.gz"
        tar -xzf "govc_Darwin_${arch}.tar.gz"
        chmod +x govc
        sudo mv govc /usr/local/bin/govc
        GOVC_PATH="govc"
        
    elif [ "$os" = "linux" ]; then
        local arch=$(uname -m)
        case "$arch" in
            x86_64) arch="x86_64" ;;
            aarch64|arm64) arch="arm64" ;;
            *) 
                echo "Unsupported Linux architecture: $arch"
                exit 1
                ;;
        esac
        
        local version=$(get_latest_govc_version)
        if [ -z "$version" ]; then
            version="v0.52.0"  # fallback
        fi
        echo "Installing govc version: $version"
        
        local download_url="https://github.com/vmware/govmomi/releases/download/${version}/govc_Linux_${arch}.tar.gz"
        echo "Downloading from: $download_url"
        download_file "$download_url" "govc_Linux_${arch}.tar.gz"
        tar -xzf "govc_Linux_${arch}.tar.gz"
        chmod +x govc
        sudo mv govc /usr/local/bin/govc
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

# Check for xmllint
if ! command_exists xmllint; then
    echo "xmllint not found, installing..."
    install_xmllint
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

# Set defaults from environment variables
GOVC_USERNAME=${GOVC_USERNAME:-'root'}
GOVC_DATASTORE=${GOVC_DATASTORE:-'datastore1'}
GOVC_VM_NAME_BASE=${GOVC_VM_NAME:-'foundry-appliance'}
GOVC_RESOURCE_POOL=${GOVC_RESOURCE_POOL:-'Resources'}

# Export credentials for validation
export GOVC_URL
export GOVC_USERNAME
export GOVC_PASSWORD
export GOVC_INSECURE=1

echo ""
echo "Validating ESXi credentials..."
echo "Connecting to vSphere at $GOVC_URL as $GOVC_USERNAME..."

# Test connection before downloading OVA
if ! "$GOVC_PATH" about >/dev/null 2>&1; then
    echo "Error: Failed to connect to ESXi host"
    echo "Please verify:"
    echo "  - GOVC_URL is correct and reachable"
    echo "  - GOVC_USERNAME and GOVC_PASSWORD are valid"
    echo "  - ESXi host is accessible on the network"
    exit 1
fi

echo "✓ Successfully connected to ESXi host"

# Set OVA_URL after credentials are validated
if [ -z "$OVA_URL" ]; then
    # Get latest release URL if not provided
    OVA_URL=$(get_latest_release_url)
fi

# Extract version from OVA URL for VM naming
OVA_FILENAME=$(basename "$OVA_URL")
if echo "$OVA_FILENAME" | grep -q "v[0-9]"; then
    VERSION=$(echo "$OVA_FILENAME" | grep -o "v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" | head -1)
    GOVC_VM_NAME="${GOVC_VM_NAME_BASE}-${VERSION}"
else
    GOVC_VM_NAME="$GOVC_VM_NAME_BASE"
fi

echo "VM will be named: $GOVC_VM_NAME"

# Check if OVA already exists and is from the same URL
if [ -f "$OVA_FILENAME" ] && [ -f "${OVA_FILENAME}.url" ]; then
    CACHED_URL=$(cat "${OVA_FILENAME}.url" 2>/dev/null || echo "")
    if [ "$CACHED_URL" = "$OVA_URL" ]; then
        echo "Using cached OVA: $OVA_FILENAME"
        echo "File size: $(ls -lh "$OVA_FILENAME" | awk '{print $5}')"
        cp "$OVA_FILENAME" foundry.ova
    else
        echo "OVA URL changed, downloading new version..."
        echo "Downloading foundry.ova from: $OVA_URL"
        echo "This may take several minutes depending on your connection..."
        download_file "$OVA_URL" "foundry.ova"
        # Cache the downloaded file and URL
        cp foundry.ova "$OVA_FILENAME"
        echo "$OVA_URL" > "${OVA_FILENAME}.url"
        echo "Download completed. File size: $(ls -lh foundry.ova | awk '{print $5}')"
    fi
else
    echo "Downloading foundry.ova from: $OVA_URL"
    echo "This may take several minutes depending on your connection..."
    download_file "$OVA_URL" "foundry.ova"
    
    if [ ! -f foundry.ova ]; then
        echo "Error: Failed to download foundry.ova"
        exit 1
    fi
    
    # Cache the downloaded file and URL
    cp foundry.ova "$OVA_FILENAME"
    echo "$OVA_URL" > "${OVA_FILENAME}.url"
    echo "Download completed. File size: $(ls -lh foundry.ova | awk '{print $5}')"
fi

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

if ! command_exists python3; then
    # Use sed-based approach for systems without Python
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

echo ""
echo "Starting VM import..."

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
