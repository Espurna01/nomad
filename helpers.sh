# helpers functions for forja scripts


# output formatting
info()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }
success() { printf "\033[1;32m[SUCCESS]\033[0m %s\n" "$*"; }

# idempotent set key value on configuration file
set_key_value() { # pls don't use | as key/value
  local key="$1" value="$2" file="$3"
  local line="${key}=${value}"
  if grep -q "^\s*${key}\s*=" "$file" 2>/dev/null; then
    sed -i "s|^\s*${key}\s*=.*|${line}|" "$file"
  else
    echo "${line}" >> "$file"
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

