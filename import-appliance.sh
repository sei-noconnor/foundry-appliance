#!/bin/bash 

# Usage: export GOVC_URL=<server> GOVC_PASSWORD=<password> && ./import-appliance.sh [GOVC_USERNAME] [DATASTORE] [VM_NAME] [RESOURCE_POOL]
# Or via curl: curl -sSL https://raw.githubusercontent.com/your-repo/foundry-appliance/main/import-appliance.sh | bash -s -- <GOVC_URL> <GOVC_PASSWORD> [GOVC_USERNAME] [DATASTORE] [VM_NAME] [RESOURCE_POOL]
# When using curl, the first two arguments must be GOVC_URL and GOVC_PASSWORD
# For local execution, use environment variables: GOVC_URL, GOVC_PASSWORD

set -e  # Exit on any error

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

# Create temporary working directory
TEMP_DIR=$(mktemp -d)
echo "Working in temporary directory: $TEMP_DIR"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
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
    
    if [[ "$os" == "macos" ]]; then
        curl -L -o govc_darwin_amd64.gz \
            https://github.com/vmware/govmomi/releases/latest/download/govc_darwin_amd64.gz
        gunzip govc_darwin_amd64.gz
        chmod +x govc_darwin_amd64
        sudo mv govc_darwin_amd64 /usr/local/bin/govc
    elif [[ "$os" == "linux" ]]; then
        curl -L -o govc_linux_amd64.gz \
            https://github.com/vmware/govmomi/releases/latest/download/govc_linux_amd64.gz
        gunzip govc_linux_amd64.gz
        chmod +x govc_linux_amd64
        sudo mv govc_linux_amd64 /usr/local/bin/govc
    else
        echo "Unsupported OS for govc installation"
        exit 1
    fi
}

# Check and install required applications
echo "Checking for required applications..."

if ! command_exists xmllint; then
    echo "xmllint not found, installing..."
    install_xmllint
else
    echo "xmllint found"
fi

if ! command_exists govc; then
    echo "govc not found, installing..."
    install_govc
else
    echo "govc found"
fi

echo "All required applications are available"
echo ""

# 1) Download and extract the OVA
cd "$TEMP_DIR"

echo "Downloading foundry.ova..."
curl -L -o foundry.ova \
  https://incuspub.blob.core.usgovcloudapi.net/ova/appliance/foundry-appliance-v0.10.2.ova

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
pushd foundry-ova
# Use Python for XML editing since xmllint alone doesn't support deletion
python3 -c "
import xml.etree.ElementTree as ET
import glob
import sys

for ovf_file in glob.glob('*.ovf'):
    try:
        # Parse the XML file
        tree = ET.parse(ovf_file)
        root = tree.getroot()
        
        # Define namespaces
        namespaces = {
            'ovf': 'http://schemas.dmtf.org/ovf/envelope/1',
            'rasd': 'http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData',
            'vssd': 'http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData'
        }
        
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

# Update the manifest file with new checksums
echo "Updating manifest file..."
for ovf_file in *.ovf; do
    if [ -f "$ovf_file" ]; then
        ovf_hash=$(openssl sha256 "$ovf_file" | cut -d' ' -f2)
        ovf_size=$(stat -f%z "$ovf_file" 2>/dev/null || stat -c%s "$ovf_file" 2>/dev/null)
        
        # Update .mf file
        mf_file="${ovf_file%.ovf}.mf"
        if [ -f "$mf_file" ]; then
            # Replace the OVF hash in the manifest
            sed -i.bak "s/SHA256(${ovf_file})=.*/SHA256(${ovf_file})= ${ovf_hash}/" "$mf_file" || \
            echo "SHA256(${ovf_file})= ${ovf_hash}" >> "$mf_file"
            rm -f "$mf_file.bak"
            echo "Updated manifest for $ovf_file"
        fi
    fi
done

# Repackage the modified OVA
echo "Repackaging OVA..."
rm -f ../foundry-modified.ova
tar -cf ../foundry-modified.ova *.ovf *.vmdk *.mf
echo "Created foundry-modified.ova"
popd

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

echo "Connecting to vSphere at $GOVC_URL as $GOVC_USERNAME..."

govc import.ovf \
  -ds="$GOVC_DATASTORE" \
  -name="$GOVC_VM_NAME" \
  -pool="$GOVC_RESOURCE_POOL" \
  foundry-ova/foundry-appliance-v0.10.2.ovf

# 4) Power on and verify
govc vm.power -on "$GOVC_VM_NAME"
govc vm.info "$GOVC_VM_NAME"
