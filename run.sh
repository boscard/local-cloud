#!/usr/bin/env bash
#set -x

script_file="$(dirname $0)/$(basename $0)"

if [[ -L "${script_file}" ]]
then
	script_file=$(readlink -f "${script_file}")
fi

: ${CONFIG_FILE:="config.yaml"}

backend=$(yq -r .backend ${CONFIG_FILE})

if [[ ${backend} != "null" ]] && [[ ! -f "$(dirname ${script_file})/backend-${backend}.sh" ]]
then
	echo "Please configure valid backend to use!"
	exit 254
fi

source $(dirname ${script_file})/backend-${backend}.sh

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
