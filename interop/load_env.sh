# Source me. Loads ../.env, derives ANTHROPIC_API_KEY (for the Node/Go agents) from the Ballerina BAL_CONFIG_DATA line if it is
# not set, then unsets BAL_CONFIG_DATA: the interop rigs declare no anthropicApiKey and `bal` rejects an unused configuration value.
[ -f "$(dirname "${BASH_SOURCE[0]}")/../.env" ] && . "$(dirname "${BASH_SOURCE[0]}")/../.env"
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -n "${BAL_CONFIG_DATA:-}" ]; then
  ANTHROPIC_API_KEY=$(printf '%s' "$BAL_CONFIG_DATA" | sed -n 's/.*"\(sk-ant-[^"]*\)".*/\1/p'); export ANTHROPIC_API_KEY
fi
case "${ANTHROPIC_API_KEY:-}" in sk-ant-PASTE*|"") unset ANTHROPIC_API_KEY;; esac
unset BAL_CONFIG_DATA
