# amux shell integration for zsh
# Writes session state to AMUX_STATUS_FILE so the sidebar can show activity.

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
