#!/usr/bin/env bash
set -euo pipefail

OUTPUT="CODEBASE_REPORT.md"

get_extension() {
    local f="$1"
    local base="${f##*/}"
    if [[ "$base" == *.* ]]; then
        echo "${base##*.}"
    else
        echo ""
    fi
}

ext_to_language() {
    case "$1" in
        zig) echo "Zig" ;;
        c|h) echo "C" ;;
        glsl|vert|frag|comp|geom) echo "GLSL" ;;
        sh) echo "Shell" ;;
        py) echo "Python" ;;
        js|ts) echo "JavaScript/TypeScript" ;;
        json|jsonc) echo "JSON" ;;
        toml|yaml|yml) echo "Config" ;;
        md) echo "Markdown" ;;
        css) echo "CSS" ;;
        html) echo "HTML" ;;
        nix) echo "Nix" ;;
        *) echo "Other ($1)" ;;
    esac
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

while IFS= read -r -d '' file; do
    ext="$(get_extension "$file")"
    [[ -z "$ext" ]] && continue

    lang="$(ext_to_language "$ext")"
    lines="$(wc -l < "$file")"
    printf '%s\t%s\t%s\n' "$lang" "$lines" "$file"
done < <(git ls-files -z) > "$tmpdir/raw.tsv"

total_files=0
total_lines=0

{
    echo "# Codebase Report"
    echo ""
    echo "Generated on $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    echo "## Summary"
    echo ""

    printf "| %-25s | %12s | %12s |\n" "Language" "Files" "Lines of Code"
    printf "| %-25s | %12s | %12s |\n" "---" "---" "---"

    sort -t$'\t' -k1,1 -k3,3rn "$tmpdir/raw.tsv" \
        | awk -F'\t' '{files[$1]++; lines[$1]+=$2} END {for (l in files) printf "%s\t%d\t%d\n", l, files[l], lines[l]}' \
        | sort -t$'\t' -k3,3rn \
        | while IFS=$'\t' read -r lang count loc; do
            printf "| %-25s | %12d | %12d |\n" "$lang" "$count" "$loc"
            total_files=$((total_files + count))
            total_lines=$((total_lines + loc))
        done

    echo ""
    echo "---"
    echo ""

    echo "## Files by Language"
    echo ""

    current_lang=""
    sort -t$'\t' -k1,1 -k3,3rn "$tmpdir/raw.tsv" | while IFS=$'\t' read -r lang lines file; do
        if [[ "$lang" != "$current_lang" ]]; then
            if [[ -n "$current_lang" ]]; then
                echo ""
            fi
            current_lang="$lang"
            echo "### $lang"
            echo ""
            printf "| %-60s | %15s |\n" "File" "Lines"
            printf "| %-60s | %15s |\n" "---" "---"
        fi
        printf "| %-60s | %15d |\n" "\`$file\`" "$lines"
    done

    echo ""
} > "$OUTPUT"

total_files=$(wc -l < "$tmpdir/raw.tsv")
total_lines=$(awk -F'\t' '{s+=$2} END {print s}' "$tmpdir/raw.tsv")

echo "Report written to $OUTPUT ($total_files files, $total_lines total lines)"
