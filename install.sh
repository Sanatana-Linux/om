#!/bin/sh
set -e

# ANSI color codes — empty when stdout/stderr is not a terminal
if [ -t 2 ]; then
	BOLD='\033[1m'
	DIM='\033[2m'
	CYAN='\033[36m'
	GREEN='\033[32m'
	YELLOW='\033[33m'
	RESET='\033[0m'
else
	BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RESET=''
fi

INSTALL_CMD="nix profile add 'https://kepr.uk/nina/archive/HEAD.tar.gz#nina'"

banner() {
	printf >&2 '\n'
	printf >&2 "${CYAN}   ___${RESET}\n"
	printf >&2 "${CYAN}  / _ \\ _ __ ___   ___${RESET}\n"
	printf >&2 "${CYAN} | | | | '_ \` _ \\ / _ \\${RESET}\n"
	printf >&2 "${CYAN} | |_| | | | | | | (_) |${RESET}\n"
	printf >&2 "${CYAN}  \\___/|_| |_| |_|\\___/${RESET}\n"
	printf >&2 '\n'
	printf >&2 "  ${BOLD}NixOS Operations Manager${RESET}  ${DIM}·${RESET}  ${DIM}fork of kepr.uk/nina${RESET}\n"
	printf >&2 '\n'
}

main() {
	banner

	printf >&2 "  om is installed directly with nix:\n\n"
	printf >&2 "    ${YELLOW}%s${RESET}\n\n" "$INSTALL_CMD"

	# Always prompt via /dev/tty so this works when piped through curl | sh.
	# /dev/tty's permission bits are readable even with no controlling
	# terminal attached (e.g. CI, provisioning, SSH without a pty) — only an
	# actual open reveals that, so probe it instead of using a plain -r test.
	if ! (: </dev/tty) 2>/dev/null; then
		printf >&2 "  No terminal to prompt on — run this yourself when ready:\n\n"
		printf >&2 "    ${YELLOW}%s${RESET}\n\n" "$INSTALL_CMD"
		exit 0
	fi
	printf >&2 "  Run it now? [Y/n] "
	read -r answer </dev/tty
	case "${answer:-y}" in
	[nN]*)
		printf >&2 '\n  Copy the command above and run it whenever you are ready.\n\n'
		exit 0
		;;
	esac
	printf >&2 '\n'

	nix profile add 'https://kepr.uk/nina/archive/HEAD.tar.gz#nina'

	printf >&2 '\n'
	printf >&2 "  ${GREEN}${BOLD}✓ Thank you for installing om!${RESET}\n"
	printf >&2 '\n'
	printf >&2 "  ${BOLD}Getting started${RESET}\n\n"
	printf >&2 "    ${CYAN}om help${RESET}       — explore what om can do\n"
	printf >&2 "    ${CYAN}om goodbye${RESET}    — remove om cleanly if it's not a good fit\n"
	printf >&2 '\n'
	printf >&2 "  ${BOLD}Issues & feedback${RESET}\n\n"
	printf >&2 "    ${DIM}https://${RESET}kepr.uk/nina   ${DIM}— original project by Asha Software${RESET}\n"
	printf >&2 '\n'
}

main
