# xmux ZDOTDIR injection entry point.
# Loaded by zsh before any user dotfiles because ZDOTDIR was set to this dir.
# Restores the original ZDOTDIR so all user dotfiles (.zprofile, .zshrc, …)
# are found in the right place, then queues the xmux integration to load
# once the shell is interactive.

# Restore original ZDOTDIR so subsequent zsh dotfiles come from the right place.
if [[ -n "${_XMUX_ORIG_ZDOTDIR+x}" ]]; then
    ZDOTDIR="${_XMUX_ORIG_ZDOTDIR}"
    [[ -z "$ZDOTDIR" ]] && unset ZDOTDIR
else
    unset ZDOTDIR
fi

# Source the user's .zshenv from the (now restored) original location.
_xmux_orig_zshenv="${ZDOTDIR:-$HOME}/.zshenv"
[[ -f "$_xmux_orig_zshenv" ]] && source "$_xmux_orig_zshenv"
unset _xmux_orig_zshenv

# Queue integration to load on the first prompt (after .zshrc has run).
if [[ -n "$XMUX_LOG" && -n "$XMUX_RESOURCES_DIR" ]]; then
    _xmux_load_integration() {
        builtin source "${XMUX_RESOURCES_DIR}/shell-integration/zsh/xmux-integration"
        precmd_functions=(${precmd_functions:#_xmux_load_integration})
        builtin unfunction _xmux_load_integration 2>/dev/null
    }
    typeset -ag precmd_functions
    precmd_functions=(_xmux_load_integration $precmd_functions)
fi
