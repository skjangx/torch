# cmux patches for the bundled Ghostty zsh integration.
#
# Keep nested SSH hops aligned with the active local TERM. Users who opt into
# a portable TERM such as xterm-256color should not be silently upgraded to
# xterm-ghostty on the first hop, because deeper non-integrated hops will then
# inherit a TERM that may not exist on downstream servers.

if [[ "${GHOSTTY_SHELL_FEATURES:-}" == *ssh-* ]]; then
  ssh() {
    emulate -L zsh
    setopt local_options no_glob_subst

    local current_term ssh_term ssh_opts
    current_term="${TERM:-xterm-256color}"
    ssh_term="$current_term"
    ssh_opts=()

    # Configure environment variables for remote session.
    if [[ "$GHOSTTY_SHELL_FEATURES" == *ssh-env* ]]; then
      ssh_opts+=(-o "SetEnv COLORTERM=truecolor")
      ssh_opts+=(-o "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION")
    fi

    # Only try to install/use xterm-ghostty when the active local TERM already
    # uses it. If the user selected a portable TERM such as xterm-256color,
    # keep that TERM across SSH hops so nested sessions remain broadly
    # compatible even when Ghostty shell integration is unavailable remotely.
    if [[ "$GHOSTTY_SHELL_FEATURES" == *ssh-terminfo* && "$current_term" == "xterm-ghostty" ]]; then
      local ssh_user ssh_hostname

      ssh_term="xterm-256color"

      while IFS=' ' read -r ssh_key ssh_value; do
        case "$ssh_key" in
          user) ssh_user="$ssh_value" ;;
          hostname) ssh_hostname="$ssh_value" ;;
        esac
        [[ -n "$ssh_user" && -n "$ssh_hostname" ]] && break
      done < <(command ssh -G "$@" 2>/dev/null)

      if [[ -n "$ssh_hostname" ]]; then
        local ssh_target="${ssh_user}@${ssh_hostname}"

        # Check if terminfo is already cached.
        if [[ -n "${GHOSTTY_BIN_DIR:-}" && -x "$GHOSTTY_BIN_DIR/ghostty" ]] &&
           "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --host="$ssh_target" >/dev/null 2>&1; then
          ssh_term="xterm-ghostty"
        elif (( $+commands[infocmp] )); then
          local ssh_terminfo ssh_cpath_dir ssh_cpath

          ssh_terminfo=$(infocmp -0 -x xterm-ghostty 2>/dev/null)

          if [[ -n "$ssh_terminfo" ]]; then
            print "Setting up xterm-ghostty terminfo on $ssh_hostname..." >&2

            ssh_cpath_dir=$(mktemp -d "/tmp/ghostty-ssh-$ssh_user.XXXXXX" 2>/dev/null) || ssh_cpath_dir="/tmp/ghostty-ssh-$ssh_user.$$"
            ssh_cpath="$ssh_cpath_dir/socket"

            if builtin print -r "$ssh_terminfo" | command ssh "${ssh_opts[@]}" -o ControlMaster=yes -o ControlPath="$ssh_cpath" -o ControlPersist=60s "$@" '
              infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
              command -v tic >/dev/null 2>&1 || exit 1
              mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
              exit 1
            ' 2>/dev/null; then
              ssh_term="xterm-ghostty"
              ssh_opts+=(-o "ControlPath=$ssh_cpath")

              # Cache successful installation when the helper is available.
              if [[ -n "${GHOSTTY_BIN_DIR:-}" && -x "$GHOSTTY_BIN_DIR/ghostty" ]]; then
                "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --add="$ssh_target" >/dev/null 2>&1 || true
              fi
            else
              print "Warning: Failed to install terminfo." >&2
            fi
          else
            print "Warning: Could not generate terminfo data." >&2
          fi
        else
          print "Warning: ghostty command not available for cache management." >&2
        fi
      fi
    fi

    TERM="$ssh_term" command ssh "${ssh_opts[@]}" "$@"
  }
fi
