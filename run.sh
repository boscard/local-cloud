#!/usr/bin/env bash
#set -x

script_file="$(dirname $0)/$(basename $0)"

if [[ -L "${script_file}" ]]
then
	script_file=$(readlink -f "${script_file}")
fi

: ${CONFIG_FILE:="config.yaml"}

while getopts "c:" opt; do
	case ${opt} in
		c)
			CONFIG_FILE="${OPTARG}"
			;;
		*)
			echo "Usage: $0 [-c config_file] <action>"
			exit 1
			;;
	esac
done
shift $((OPTIND - 1))

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
	echo "Usage: $0 [-c config_file] <action>"
	echo "Actions: destroy, test"
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
