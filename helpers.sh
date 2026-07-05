# helpers functions for forja scripts


# output formatting
info()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }
success() { printf "\033[1;32m[SUCCESS]\033[0m %s\n" "$*"; }

# idempotent set key value on configuration file
set_key_value() {
  local key="$1" value="$2" file="$3"
  local line="${key}=${value}"
  # if starts with (anyspaces)KEY(anyspaces)= then we sed that line if not we add configuration
  if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
    sudo sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*|${line}|" "$file"
  else
    echo "${line}" | sudo tee -a "$file" >/dev/null
  fi
}

# enforce use of .env
enforce_env() {
	if [ ! -f .env ]; then
		error ".env not found in working direcotry. Copy template_.env to .env and set your values." >&2
		exit 2
	fi
	source .env
}

NOTES=()
append_note() { NOTES+=("$1"); warn "$1"; }
print_notes() { for i in "${NOTES[@]}"; do warn $i; done }
