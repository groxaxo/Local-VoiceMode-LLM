# Issue #14 compatibility shim: the Supertonic 3 repository URL used by older
# installers is not publicly resolvable, which makes macOS installs fail during
# git clone. Redirect that clone target to the maintained Supertonic repository
# so the ONNX fallback path can complete.
if command -v git >/dev/null 2>&1; then
  _supertonic_compat_git() {
    local args=()
    local arg
    for arg in "$@"; do
      case "$arg" in
        *supertonic-express-3*)
          arg="${arg//supertonic-express-3/supertonic-express}"
          ;;
      esac
      args+=("$arg")
    done
    command git "${args[@]}"
  }

  git() {
    _supertonic_compat_git "$@"
  }

  export SUPERTONIC_REPO_URL="https://github.com/groxaxo/supertonic-express"
fi
