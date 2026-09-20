# agent-tmux-shell.zsh: make every CLI agent (claude, glm, deepseek, kimi, muse, codex, …) open inside a
# named tmux session by default (via agent-tmux.sh), so David never has to type the wrapper.
# Install: cp scripts/mac/agent-tmux-shell.zsh ~/bin/ && add `source ~/bin/agent-tmux-shell.zsh`
# to ~/.zshrc. Source of truth lives in the repo (scripts/mac/).
#
# The real tool runs directly (no tmux) when:
#   - we are already inside tmux ($TMUX set): no nesting;
#   - the call is not interactive (stdin/stdout not a terminal): scripts, pipes, hooks;
#   - the call is one-shot: -p/--print, --version, -h/--help, or a subcommand like `codex exec`.
# AGENT_TMUX_LAUNCHER overrides the wrapper path and AGENT_TMUX_ASSUME_TTY=1 skips the tty check
# (both only for tests).

_agent_tmux_run() {
  local tool=$1; shift
  local launcher=${AGENT_TMUX_LAUNCHER:-$HOME/bin/agent-tmux.sh}
  if [[ -n ${TMUX:-} || ! -x $launcher ]]; then
    command "$tool" "$@"; return
  fi
  if [[ -z ${AGENT_TMUX_ASSUME_TTY:-} && ( ! -t 0 || ! -t 1 ) ]]; then
    command "$tool" "$@"; return
  fi
  local a
  for a in "$@"; do
    case $a in
      -p|--print|--version|-v|-h|--help|exec|login|logout|update|mcp|config|doctor)
        command "$tool" "$@"; return ;;
    esac
  done
  "$launcher" "$tool" "$PWD" "$@"
}

# Every CLI agent David launches by hand, including his own launchers in ~/bin (glm, deepseek,
# kimi-claude wrap `claude` against another provider). Add a name here when a new one appears.
AGENT_TMUX_TOOLS=(claude glm deepseek kimi-claude kimi muse codex cursor-agent grok opencode qwen dsh)
for _t in "${AGENT_TMUX_TOOLS[@]}"; do
  eval "${_t}() { _agent_tmux_run ${_t} \"\$@\"; }"
done
unset _t
