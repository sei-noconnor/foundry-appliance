#!/bin/bash

# Foundry Appliance OVA Download and Processing Script
# Downloads the latest Foundry appliance OVA and processes it for ESXi compatibility
#
# Usage: ./download-ova.sh [ova_url] [output_dir]
#   ova_url: Optional URL to download (defaults to latest GitHub release)
#   output_dir: Optional output directory (defaults to ./output)

set -e  # Exit on any error

# Default values
OUTPUT_DIR="$(cd "${2:-./output}" 2>/dev/null && pwd || echo "$(pwd)/${2:-output}")"
WORK_DIR="$HOME/.foundry-appliance-download"

# Create directories
mkdir -p "$OUTPUT_DIR"
mkdir -p "$WORK_DIR"

echo "Working directory: $WORK_DIR"
echo "Output directory: $OUTPUT_DIR"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$WORK_DIR"/foundry-ova 2>/dev/null || true
    rm -f "$WORK_DIR"/github_response.json 2>/dev/null || true
}
trap cleanup EXIT

# Function to check if command exists
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

# Function to get latest release URL from GitHub API
get_latest_release_url() {
    local tool=$(detect_download_tool)
    local api_url="https://api.github.com/repos/cmu-sei/foundry-appliance/releases/latest"
    local temp_response="$WORK_DIR/github_response.json"
    local fallback_url="https://incuspub.blob.core.usgovcloudapi.net/ova/appliance/foundry-appliance-v0.10.2.ova"
    
    case "$tool" in
        curl)
            if curl -s "$api_url" > "$temp_response" 2>/dev/null && [ -s "$temp_response" ]; then
                :
            else
                echo "$fallback_url"
                return
            fi
            ;;
        wget)
            if wget -q -O "$temp_response" "$api_url" 2>/dev/null && [ -s "$temp_response" ]; then
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

# Check for required applications
echo "Checking for required applications..."

if ! command_exists python3; then
    echo "Warning: Python3 not found. Will use simplified sound card removal."
fi

echo "All required applications available"
echo ""

# Determine OVA URL
if [ -n "$1" ]; then
    OVA_URL="$1"
    echo "Using provided OVA URL: $OVA_URL"
else
    echo "Getting latest release URL..."
    OVA_URL=$(get_latest_release_url)
    echo "Using latest release: $OVA_URL"
fi

# Extract version from OVA URL for naming
OVA_FILENAME=$(basename "$OVA_URL")
if echo "$OVA_FILENAME" | grep -q "v[0-9]"; then
    VERSION=$(echo "$OVA_FILENAME" | grep -o "v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" | head -1)
    OUTPUT_FILENAME="foundry-appliance-${VERSION}.ova"
else
    OUTPUT_FILENAME="foundry-appliance.ova"
fi

cd "$WORK_DIR"

# Check if OVA already exists and is from the same URL
if [ -f "$OVA_FILENAME" ] && [ -f "${OVA_FILENAME}.url" ]; then
    CACHED_URL=$(cat "${OVA_FILENAME}.url" 2>/dev/null || echo "")
    if [ "$CACHED_URL" = "$OVA_URL" ]; then
        echo "Using cached OVA: $OVA_FILENAME"
        echo "File size: $(ls -lh "$OVA_FILENAME" | awk '{print $5}')"
        cp "$OVA_FILENAME" foundry.ova
    else
        echo "OVA URL changed, downloading new version..."
        echo "Downloading from: $OVA_URL"
        echo "This may take several minutes..."
        download_file "$OVA_URL" "foundry.ova"
        cp foundry.ova "$OVA_FILENAME"
        echo "$OVA_URL" > "${OVA_FILENAME}.url"
        echo "Download completed. File size: $(ls -lh foundry.ova | awk '{print $5}')"
    fi
else
    echo "Downloading from: $OVA_URL"
    echo "This may take several minutes..."
    download_file "$OVA_URL" "foundry.ova"
    
    if [ ! -f foundry.ova ]; then
        echo "Error: Failed to download foundry.ova"
        exit 1
    fi
    
    cp foundry.ova "$OVA_FILENAME"
    echo "$OVA_URL" > "${OVA_FILENAME}.url"
    echo "Download completed. File size: $(ls -lh foundry.ova | awk '{print $5}')"
fi

echo "Extracting OVA..."
rm -rf foundry-ova
mkdir foundry-ova
if tar -tf foundry.ova >/dev/null 2>&1; then
    tar -C foundry-ova -xf foundry.ova
else
    echo "Error: foundry.ova appears to be corrupted or not a valid OVA file"
    exit 1
fi

# Process OVF to remove sound card
cd foundry-ova

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

if command_exists python3; then
    echo "Using Python for precise sound card removal..."
    python3 -c "
import xml.etree.ElementTree as ET
import glob
import sys

for ovf_file in glob.glob('*.ovf'):
    try:
        tree = ET.parse(ovf_file)
        root = tree.getroot()
        
        items_removed = 0
        for parent in root.iter():
            items_to_remove = []
            for child in list(parent):
                if child.tag.endswith('Item'):
                    for subchild in child:
                        if subchild.tag.endswith('ResourceType') and subchild.text == '35':
                            items_to_remove.append(child)
                            break
            
            for item in items_to_remove:
                parent.remove(item)
                items_removed += 1
                print(f'Removed sound card item (ResourceType 35)')
        
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
else
    echo "Using simplified sound card removal (sed-based)..."
    cp "$OVF_FILE" "${OVF_FILE}.backup"
    sed -i.tmp '/ResourceType>35<\/rasd:ResourceType>/,/<\/Item>/d' "$OVF_FILE" 2>/dev/null || {
        echo "Warning: Could not remove sound card automatically. Proceeding with original OVF."
        cp "${OVF_FILE}.backup" "$OVF_FILE"
    }
    rm -f "${OVF_FILE}.tmp" 2>/dev/null
    echo "Sound card removal completed (simplified method)"
fi

# Update manifest file
if [ -f "$OVF_FILE" ]; then
    echo "Updating manifest file..."
    
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
            cp "$mf_file" "${mf_file}.backup"
            sed -i.tmp "s/SHA256(${OVF_FILE})=.*/SHA256(${OVF_FILE})= ${ovf_hash}/" "$mf_file" 2>/dev/null || {
                echo "SHA256(${OVF_FILE})= ${ovf_hash}" > "$mf_file"
            }
            rm -f "${mf_file}.tmp" 2>/dev/null
            echo "Updated manifest for $OVF_FILE"
        fi
    fi
fi

# Repackage as OVA
cd "$WORK_DIR"
echo "Repackaging processed OVA..."
rm -f processed-foundry.ova
(cd foundry-ova && tar -cf ../processed-foundry.ova *.ovf *.vmdk *.mf)

# Move to output directory
cp processed-foundry.ova "$OUTPUT_DIR/$OUTPUT_FILENAME"

echo ""
echo "✓ OVA processing completed successfully!"
echo "Processed OVA saved to: $OUTPUT_DIR/$OUTPUT_FILENAME"
echo "File size: $(ls -lh "$OUTPUT_DIR/$OUTPUT_FILENAME" | awk '{print $5}')"
echo ""
echo "The OVA is now ready for import into ESXi."
echo "You can use import-ova.sh or import manually via the ESXi web interface."