#!/usr/bin/env bash
# Stage 3: Claude Code settings for the HOST (for the times you run claude outside the container).
# The container has its own managed settings baked in: container/managed-settings.json.
#
#   03-claude-settings.sh            merge hardening into ~/.claude/settings.json (backup kept)
#   03-claude-settings.sh --managed  also install /etc/claude-code/managed-settings.json (sudo)
#                                    so that no repository can turn hooks back on
#
# Existing settings are kept. Where a key exists on both sides, the hardened value wins for
# scalars and lists are merged.
set -euo pipefail
command -v jq >/dev/null || { echo "missing: jq" >&2; exit 1; }

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

HARDEN="$(cat <<'JSON'
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "network": {
      "strictAllowlist": true,
      "allowedDomains": ["api.anthropic.com", "registry.npmjs.org", "pypi.org", "files.pythonhosted.org"]
    },
    "credentials": {
      "files": [
        { "path": "~/.ssh", "mode": "deny" },
        { "path": "~/.aws/credentials", "mode": "deny" },
        { "path": "~/.config/gh", "mode": "deny" },
        { "path": "~/.docker/config.json", "mode": "deny" },
        { "path": "~/.local/share/containers/storage/secrets", "mode": "deny" }
      ],
      "envVars": [
        { "name": "GITHUB_TOKEN", "mode": "deny" },
        { "name": "GH_TOKEN", "mode": "deny" },
        { "name": "NPM_TOKEN", "mode": "deny" }
      ]
    }
  },
  "permissions": {
    "disableBypassPermissionsMode": "disable",
    "deny": [
      "Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(~/.config/gh/**)", "Read(~/.docker/**)",
      "Read(~/.local/share/containers/storage/secrets/**)"
    ]
  }
}
JSON
)"

# Deep merge: objects recurse, arrays are unioned, scalars take the hardened value.
jq -n --argjson cur "$(cat "$SETTINGS")" --argjson add "$HARDEN" '
  def merge(a; b):
    if (a|type) == "object" and (b|type) == "object" then
      reduce ((a|keys) + (b|keys) | unique)[] as $k ({};
        .[$k] = (if (a|has($k)) and (b|has($k)) then merge(a[$k]; b[$k])
                 elif (b|has($k)) then b[$k] else a[$k] end))
    elif (a|type) == "array" and (b|type) == "array" then (a + b | unique)
    else b end;
  merge($cur; $add)' > "$SETTINGS.new"
mv "$SETTINGS.new" "$SETTINGS"
echo "Updated $SETTINGS (backup alongside). Check it with /sandbox and 'claude doctor'."

if [ "${1:-}" = "--managed" ]; then
  # Managed settings outrank project, local, user and --settings values.
  sudo mkdir -p /etc/claude-code
  sudo tee /etc/claude-code/managed-settings.json >/dev/null <<'JSON'
{
  "allowManagedHooksOnly": true,
  "enableAllProjectMcpServers": false
}
JSON
  sudo chmod 0644 /etc/claude-code/managed-settings.json
  echo "Installed /etc/claude-code/managed-settings.json. Confirm with /status: 'Enterprise managed settings (file)'."
  echo "Note: this blocks your own user-level hooks too. Put hooks you want into the managed file."
fi
