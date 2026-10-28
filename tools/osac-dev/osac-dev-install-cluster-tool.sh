#!/bin/sh
set -eu

install_dir="$HOME/.local/share/cluster-tool"
bin_dir="$HOME/.local/bin"
temp_dir=
mkdir -p "$HOME/.local/share" "$bin_dir"

cleanup() {
    [ -z "$temp_dir" ] || rm -rf "$temp_dir"
}
trap cleanup 0

if [ -e "$install_dir" ]; then
    if [ ! -x "$install_dir/cluster-tool" ]; then
        printf 'Existing cluster-tool directory is incomplete: %s\n' "$install_dir" >&2
        exit 1
    fi
else
    temp_dir=$(mktemp -d "$HOME/.local/share/cluster-tool.XXXXXX")
    git clone --depth 1 https://github.com/osac-project/cluster-tool.git "$temp_dir/cluster-tool"
    mv "$temp_dir/cluster-tool" "$install_dir"
fi

link="$bin_dir/cluster-tool"
target="$install_dir/cluster-tool"
if [ -L "$link" ]; then
    if [ "$(readlink "$link")" != "$target" ]; then
        printf 'Refusing to replace existing cluster-tool symlink: %s\n' "$link" >&2
        exit 1
    fi
elif [ -e "$link" ]; then
    printf 'Refusing to replace existing cluster-tool file: %s\n' "$link" >&2
    exit 1
else
    ln -s "$target" "$link"
fi

"$link" --help >/dev/null
