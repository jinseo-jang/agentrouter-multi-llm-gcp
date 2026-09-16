import json, sys

settings_path = sys.argv[1]
token = sys.argv[2]

with open(settings_path, "r", encoding="utf-8") as f:
    data = json.load(f)

env = data.setdefault("env", {})

# Remove Vertex-specific keys
for k in ["CLAUDE_CODE_USE_VERTEX", "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION"]:
    env.pop(k, None)

# Add Anthropic base URL and auth token
env["ANTHROPIC_BASE_URL"] = "http://35.198.228.226:8080/anthropic"
env["ANTHROPIC_AUTH_TOKEN"] = token

# Update model
env["ANTHROPIC_MODEL"] = "claude-sonnet-5"
data["model"] = "claude-sonnet-5"

# Suppress unsupported experimental beta headers (e.g. advisor-tool-2026-03-01)
env["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"] = "1"

with open(settings_path + ".new", "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
print("Updated settings successfully written to " + settings_path + ".new")
