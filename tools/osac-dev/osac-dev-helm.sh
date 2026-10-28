#!/usr/bin/env bash
# Shared Helm 3/4 release-listing compatibility. Source from workflow wrappers.

osac_dev_helm_list_all() {
    local version
    version=$(helm version --short) || {
        printf 'osac-dev: could not determine the Helm version\n' >&2
        return 1
    }
    case "$version" in
        v3.*|3.*)
            helm list --all "$@"
            ;;
        v4.*|4.*)
            # Helm 4 lists every status by default and removed --all.
            helm list "$@"
            ;;
        *)
            printf 'osac-dev: unsupported or unreadable Helm version %s; expected Helm 3 or 4\n' "$version" >&2
            return 1
            ;;
    esac
}
