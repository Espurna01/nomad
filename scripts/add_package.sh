#!/bin/bash
# ./scripts/add_package.sh

_usage() {
    cat << EOF
    usage: $0 <options> [package(s)]

    This script adds package + description to a file determined by options
    default or if -f is specified to there.

    OPTIONS:
        -p pacman package
        -a aur package (tool used yay)
        -b bootstrap (pacstrap?)
        -h show this message
        -f FILE specify file to append, default in packages/
EOF
}

FILE=""
PACKET_MGR=""
while getopts ":pabhf:" OPTION
do
    case $OPTION in
        h) _usage; exit 0 ;;
        p) FILE="packages/pacman_packages"; PACKET_MGR="pacman" ;;
        a) FILE="packages/aur_packages"; PACKET_MGR="yay" ;;
        b) FILE="packages/bootstrap_packages"; PACKET_MGR="yay" ;;
	f) FILE=$OPTARG; [ -z "$PACKET_MGR" ] && PACKET_MGR="pacman" ;;
        ?) echo "Invalid option: -$OPTARG" >&2; _usage; exit 1 ;;
        :)  echo "Option -$OPTARG requires an argument." >&2; _usage; exit 1 ;;
    esac
done

shift $((OPTIND - 1))

PACKAGES=("$@")

if [ -z "$FILE" ]; then
    echo "Error: No file specified. Use -[pabhf]." >&2
    exit 1
fi

if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo "Error: No packages specified." >&2
    exit 1
fi

echo "Target File: $FILE"
echo "Packages to add: ${PACKAGES[@]}"

if ! command -v "$PACKET_MGR" >/dev/null 2>/dev/null; then
	echo "$PACKET_MGR command doesn't exist can't add to file from that repository"
	exit 1
fi

for PKG in "${PACKAGES[@]}"; do
	if ! grep -q "^$PKG" $FILE; then
		if DESCRIPTION=$($PACKET_MGR -Si $PKG | sed -n 's/^Description.*: //p' 2>/dev/null) ; then
			echo "$PKG # $DESCRIPTION" >> $FILE
		fi
	fi
done
