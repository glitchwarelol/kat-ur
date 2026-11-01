#!/bin/sh
set -eu

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_name=$(basename -- "$package_dir")
search_dir=$package_dir
repo_root=

while [ "$search_dir" != / ]; do
    if [ -f "$search_dir/build.sh" ] && [ "$search_dir/build.sh" != "$package_dir/build.sh" ]; then
        repo_root=$search_dir
        break
    fi
    search_dir=$(dirname -- "$search_dir")
done

[ -n "$repo_root" ] || {
    echo "Could not find the Katana UR build.sh above $package_dir." >&2
    exit 1
}

exec "$repo_root/build.sh" \
    "$package_dir/$package_name.recipe" \
    "$package_dir"
