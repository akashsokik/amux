# amux shell integration for zsh
# Writes session state to AMUX_STATUS_FILE so the sidebar can show activity.

# Prepend agent-hooks to PATH on first prompt (after all shell init).
# .zshrc/.zprofile can rearrange PATH, so we must fix it after they run.
if [[ -n "$AMUX_AGENT_HOOKS_DIR" && -d "$AMUX_AGENT_HOOKS_DIR" ]]; then
    __amux_fix_path() {
        local -a parts=("${(@s/:/)PATH}")
        parts=("${(@)parts:#$AMUX_AGENT_HOOKS_DIR}")
        export PATH="$AMUX_AGENT_HOOKS_DIR:${(j/:/)parts}"
        add-zsh-hook -d precmd __amux_fix_path
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __amux_fix_path
fi

[[ -z "$AMUX_STATUS_FILE" ]] && return

# -- hooks ----------------------------------------------------

__amux_preexec() {
    printf 'running' > "$AMUX_STATUS_FILE"
}

__amux_precmd() {
    printf 'idle' > "$AMUX_STATUS_FILE"
}

preexec_functions+=(__amux_preexec)
precmd_functions+=(__amux_precmd)

# -- initial state --------------------------------------------

printf 'idle' > "$AMUX_STATUS_FILE"
