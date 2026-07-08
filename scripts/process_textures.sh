#!/usr/bin/env bash

# ZigCraft Texture Processing Script
# Automates conversion of high-res PBR textures to engine-ready 512px PNGs.

set -e

# Configuration
TARGET_RES=${2:-512}
MAGICK_CMD="magick"

if ! command -v "$MAGICK_CMD" &> /dev/null; then
    echo "Error: ImageMagick (magick) not found. Please install it."
    exit 1
fi

process_dir() {
    local dir=$1
    local block_name
    block_name=$(basename "$dir")
    
    echo "Processing directory: $dir (Block: $block_name)"
    
    # Patterns for mapping source files to engine suffixes
    # Format: "suffix|pattern1|pattern2|..."
    local mappings=(
        "diff|diff|albedo|color"
        "nor_gl|nor_gl|normal|nor"
        "rough|rough"
        "disp|disp|height|depth"
    )
    
    for mapping in "${mappings[@]}"; do
        local suffix
        local patterns_str
        suffix=$(echo "$mapping" | cut -d'|' -f1)
        patterns_str=$(echo "$mapping" | cut -d'|' -f2-)
        
        # Try to find a matching file
        local found=""
        
        # Split patterns by |
        IFS='|' read -ra pattern_list <<< "$patterns_str"
        
        for pattern in "${pattern_list[@]}"; do
            # Case-insensitive search for image files matching the pattern, excluding already processed ones
            local match
            match=$(find "$dir" -maxdepth 1 -type f -iname "*${pattern}*" \
                -not -name "${block_name}_${suffix}.png" \
                \( -name "*.jpg" -o -name "*.png" -o -name "*.exr" -o -name "*.tga" -o -name "*.jpeg" -o -name "*.webp" \) | head -n 1)
            
            if [ -n "$match" ]; then
                found="$match"
                break
            fi
        done
        
        if [ -n "$found" ]; then
            local target="${dir}/${block_name}_${suffix}.png"
            echo "  - Converting $(basename "$found") -> $(basename "$target") (${TARGET_RES}px)"
            $MAGICK_CMD "$found" -resize "${TARGET_RES}x${TARGET_RES}" "$target"
        else
            echo "  - No match for $suffix"
        fi
    done
}

if [ -z "$1" ]; then
    echo "Usage: $0 <directory_or_pack_root> [resolution]"
    echo "Example: $0 assets/textures/pbr-test 512"
    exit 1
fi

TARGET_PATH=$1

if [ -d "$TARGET_PATH" ]; then
    # Check if this is a single block dir or a pack root
    # If it contains subdirectories with .gitkeep or images, it's likely a pack root
    subdirs=$(find "$TARGET_PATH" -maxdepth 1 -type d -not -path "$TARGET_PATH")
    
    if [ -n "$subdirs" ]; then
        echo "Detected pack root. Processing subdirectories..."
        while IFS= read -r d; do
            process_dir "$d"
        done <<< "$subdirs"
    else
        process_dir "$TARGET_PATH"
    fi
else
    echo "Error: Directory $TARGET_PATH not found."
    exit 1
fi

echo "Done!"
