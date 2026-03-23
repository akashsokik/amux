# amux shell integration for bash
# Writes session state to AMUX_STATUS_FILE so the sidebar can show activity.

[[ -z "$AMUX_STATUS_FILE" ]] && return

# -- preexec via PS0 (bash 4.4+) ------------------------------

__amux_preexec() {
    printf 'running' > "$AMUX_STATUS_FILE"
}

PS0='$(__amux_preexec)'

# -- precmd via PROMPT_COMMAND ---------------------------------

__amux_precmd() {
    printf 'idle' > "$AMUX_STATUS_FILE"
}

if [[ -z "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="__amux_precmd"
else
    PROMPT_COMMAND="__amux_precmd;${PROMPT_COMMAND}"
fi

# -- initial state --------------------------------------------

printf 'idle' > "$AMUX_STATUS_FILE"
