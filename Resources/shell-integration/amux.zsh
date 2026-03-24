# amux shell integration for zsh
# Writes session state to AMUX_STATUS_FILE so the sidebar can show activity.

# Prepend agent-hooks to PATH so the claude/codex wrappers intercept commands
[[ -n "$AMUX_AGENT_HOOKS_DIR" && -d "$AMUX_AGENT_HOOKS_DIR" ]] && \
    [[ ":$PATH:" != *":$AMUX_AGENT_HOOKS_DIR:"* ]] && \
    export PATH="$AMUX_AGENT_HOOKS_DIR:$PATH"

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
