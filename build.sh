#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 RECIPE [OUTPUT_DIRECTORY]" >&2
    exit 2
fi

recipe=$(realpath -- "$1")
recipe_dir=$(dirname -- "$recipe")
output_dir=${2:-"$recipe_dir"}
mkdir -p -- "$output_dir"
output_dir=$(realpath -- "$output_dir")

stage=$(mktemp -d "${TMPDIR:-/tmp}/kat-ur-build.XXXXXX")
cleanup() {
    rm -rf -- "$stage"
}
trap cleanup EXIT HUP INT TERM

build_dir="$stage/build"
pkgdir="$stage/pkg"
functions_file="$stage/functions.sh"
mkdir -p -- "$build_dir" "$pkgdir"

declare -A fields=()
body_line=
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    if [[ "$line" =~ ^[[:space:]]*build[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*$ ]]; then
        body_line=$line_number
        break
    fi
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^(name|version|description|arch|dependencies|source)=(.*)$ ]]; then
        echo "Invalid metadata at $recipe:$line_number" >&2
        exit 1
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if [[ -v "fields[$key]" ]]; then
        echo "Duplicate metadata field '$key' at $recipe:$line_number" >&2
        exit 1
    fi
    if [[ "$value" =~ [[:cntrl:]] ]]; then
        echo "Metadata field '$key' contains a control character." >&2
        exit 1
    fi
    fields["$key"]=$value
done < "$recipe"

if [[ -z "$body_line" ]]; then
    echo "Recipe must define build() and package() functions." >&2
    exit 1
fi

name=${fields[name]:-}
version=${fields[version]:-}
description=${fields[description]:-}
arch=${fields[arch]:-x86_64}
dependencies=${fields[dependencies]:-}
source=${fields[source]:-}

[[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "Invalid package name." >&2; exit 1; }
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] \
    || { echo "Invalid semantic version." >&2; exit 1; }
[[ -n "$description" && ${#description} -le 240 ]] || { echo "Invalid package description." >&2; exit 1; }
[[ "$arch" == x86_64 || "$arch" == aarch64 ]] || { echo "Unsupported package architecture." >&2; exit 1; }
if [[ "$source" != local && ! "$source" =~ ^https://[^[:space:]]+$ ]]; then
    echo "Source must be a public HTTPS Git URL or local." >&2
    exit 1
fi

recipe_name=${recipe##*/}
recipe_name=${recipe_name%.recipe}
[[ "$recipe_name" == "$name" ]] || { echo "Recipe filename must match its package name ($name.recipe)." >&2; exit 1; }

if [[ -n "$dependencies" ]]; then
    IFS=, read -r -a dependency_list <<< "$dependencies"
    for dependency in "${dependency_list[@]}"; do
        dependency=${dependency//[[:space:]]/}
        [[ "$dependency" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || {
            echo "Invalid dependency name: $dependency" >&2
            exit 1
        }
    done
fi

sed -n "${body_line},\$p" "$recipe" > "$functions_file"
grep -Eq '^[[:space:]]*package[[:space:]]*\(\)[[:space:]]*\{' "$functions_file" || {
    echo "Recipe must define package() after build()." >&2
    exit 1
}
bash -n "$functions_file"

echo "Building $name v$version ($arch)"
if [[ "$source" == local ]]; then
    [[ -d "$recipe_dir/src" ]] || {
        echo "Local source requires a src/ directory next to the recipe." >&2
        exit 1
    }
    mkdir -p -- "$build_dir/source"
    cp -R -- "$recipe_dir/src/." "$build_dir/source/"
else
    git clone --depth 1 -- "$source" "$build_dir/source"
fi

(
    set -euo pipefail
    cd -- "$build_dir/source"
    export name version description arch dependencies source pkgdir="$pkgdir"
    source "$functions_file"
    declare -F build >/dev/null || { echo "Recipe does not define build()." >&2; exit 1; }
    declare -F package >/dev/null || { echo "Recipe does not define package()." >&2; exit 1; }
    build
    package
)

if ! find "$pkgdir" -type f -print -quit | grep -q .; then
    echo "package() did not place any files in pkgdir." >&2
    exit 1
fi

files_json=$(find "$pkgdir" -type f ! -name metadata.json -printf '%P\n' | sort | jq -Rsc 'split("\n") | map(select(length > 0))')
if [[ -n "$dependencies" ]]; then
    dependencies_json=$(printf '%s' "$dependencies" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')
else
    dependencies_json='[]'
fi
jq -n \
    --arg name "$name" \
    --arg version "$version" \
    --arg description "$description" \
    --arg arch "$arch" \
    --argjson dependencies "$dependencies_json" \
    --argjson files "$files_json" \
    '{name:$name,version:$version,description:$description,dependencies:$dependencies,arch:$arch,files:$files,install_script:false}' \
    > "$pkgdir/metadata.json"

archive="$output_dir/${name}-${version}-${arch}.kat"
tar -czf "$archive" -C "$pkgdir" .
sha256=$(sha256sum "$archive" | cut -d' ' -f1)
size=$(stat -c '%s' "$archive")
jq -n \
    --arg name "$name" \
    --arg version "$version" \
    --arg description "$description" \
    --arg arch "$arch" \
    --arg sha256 "$sha256" \
    --arg archive "$(basename -- "$archive")" \
    --argjson size "$size" \
    --argjson dependencies "$dependencies_json" \
    '{name:$name,version:$version,description:$description,arch:$arch,sha256:$sha256,size:$size,archive:$archive,dependencies:$dependencies}' \
    > "$output_dir/${name}-${version}-${arch}.manifest.json"

printf 'Built: %s (%s bytes, SHA-256 %s)\n' "$archive" "$size" "$sha256"
