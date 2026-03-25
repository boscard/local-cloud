#!/usr/bin/env bash
#set -x

: ${CONFIG_FILE:="config.yaml"}

backend=$(yq -r .backend ${CONFIG_FILE})

if [[ ${backend} != "null" ]] && [[ ! -f "backend-${backend}.sh" ]]
then
	echo "Please configure valid backend to use!"
	exit 254
fi

source ./backend-${backend}.sh

set -e
set -o pipefail

action="$1"


function help() {
	echo "Some help"
}

function test_ansible() {
	ensure_instances
}

case $action in
	destroy)
		clean_up;;
	test)
		test_ansible;;
	*)
		help
esac
