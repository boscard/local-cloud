# This is backend for libvirt
#set -x
function configure_network() {
	network_name=${1}
	if ! $VIRSH net-info ${network_name} > /dev/null 2>&1
	then
		echo "Network ${network_name} does not exists. Creating"
		$VIRSH net-create --file <(generate_network_config ${network_name})
	fi
}

function get_random_mac() {
	random_part=$(openssl rand -hex 3 | sed 's/\(..\)/\1:/g; s/:$//')
	static_part="52:54:00"
	echo "${static_part}:${random_part}"
}

function generate_network_config() {
	echo "<network>"
	echo "  <name>${1}</name>"
	echo "  <forward mode='nat'/>"
	echo "  <mac address='$(get_random_mac)'/>"
	echo "  <ip address='$(get_from_config .network.ip.address)' prefix='$(get_from_config .network.ip.prefix)'>"
	echo "    <dhcp>"
	echo "      <range start='$(get_from_config .network.ip.dhcp.start)' end='$(get_from_config .network.ip.dhcp.end)'/>"
	echo "    </dhcp>"
	echo "  </ip>"
	echo "</network>"
}

function get_from_config() {
	yq -r "${1}" ${CONFIG_FILE}
}

function verify_image() {
	local image_key="${1}"
	local image_path="${2}"
	local command expected actual

	command=$(get_from_config ".storage.images.${image_key}.checksum.command")
	if [[ "${command}" == "null" ]]; then
		echo "WARNING: No checksum configured for ${image_key}, skipping verification" >&2
		return 0
	fi

	expected=$(get_from_config ".storage.images.${image_key}.checksum.hash")
	actual=$("${command}" "${image_path}" | awk '{print $1}')
	if [[ "${actual}" != "${expected}" ]]; then
		echo "ERROR: ${command} mismatch for ${image_key}" >&2
		echo "  expected: ${expected}" >&2
		echo "  got:      ${actual}" >&2
		return 1
	fi

	echo "Checksum OK for ${image_key} (${command})"
	return 0
}

function check_base_images() {
	pool_name=${1}
	pool_path=$($VIRSH pool-dumpxml --pool ${pool_name} --xpath "/pool/target/path/text()")
	for image in $(get_from_config '.storage.images | keys[]')
	do
		image_name=$(get_from_config .storage.images.${image}.img)
		if ! $VIRSH vol-info --vol ${image_name} --pool $pool_name > /dev/null 2>&1
		then
			echo "Image for ${image} not found. Trying to download one"
			local max_retries=$(get_from_config ".storage.download_retries // 3")
			local attempt=1
			while [[ ${attempt} -le ${max_retries} ]]; do
				echo "Download attempt ${attempt}/${max_retries} for ${image}"
				wget -q -O ${pool_path}/${image_name} $(get_from_config .storage.images.${image}.src)
				if verify_image "${image}" "${pool_path}/${image_name}"; then
					break
				fi
				rm -f "${pool_path}/${image_name}"
				attempt=$((attempt + 1))
			done
			if [[ ${attempt} -gt ${max_retries} ]]; then
				echo "ERROR: Failed to download verified image for ${image} after ${max_retries} attempts. Aborting." >&2
				exit 1
			fi
			$VIRSH pool-refresh ${pool_name}
		fi
	done
}

function provision_volume() {
	pool_name=${1}
	base_volume=${2}
	new_volume="${3}.qcow2"
	vol_size=${4}

	if ! $VIRSH vol-info --vol ${new_volume} --pool $pool_name > /dev/null 2>&1
	then
		$VIRSH vol-create-as --pool ${pool_name} --name ${new_volume} --capacity ${vol_size} --format qcow2 --backing-vol ${base_volume} --backing-vol-format qcow2
	fi
}

function cloud_init_generate_metadata() {
	echo "instance-id: $(cat /proc/sys/kernel/random/uuid)"
}

function cloud_init_generate_network_config() {
	cat <<EOF
version: 2
ethernets:
  all-en:
    match:
      name: "en*"
    dhcp4: True
EOF
}
function cloud_init_generate_user_data_for_family() {
	vm_family="${1}"
	case $vm_family in
		debian)
			echo "packages:"
			echo "  - qemu-guest-agent"
			echo "runcmd:"
			echo "  - ['systemctl', 'enable', '--now', 'qemu-guest-agent']"
			;;
		*)
			echo "Unsupported family!" >&2
			;;
	esac
}
function cloud_init_generate_user_data() {
	vm_family="${1}"
	local vm="${2}"
	local vm_user
	vm_user=$(get_from_config '.instances.vms."'"${vm}"'".username')
	if [[ "${vm_user}" == "null" || -z "${vm_user}" ]]; then
		vm_user=$(id -un)
	fi
	cat <<EOF
#cloud-config
timezone: $(timedatectl show | grep Timezone | awk -F '=' '{ print $2 }')
chpasswd:
  expire: False
disable_root: True
ssh_pwauth: False
growpart:
  devices: [/]
  ignore_growroot_disabled: False
  mode: auto
users:
  - name: ${vm_user}
    groups: [sudo]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $(if [[ -f ~/.ssh/id_ed25519.pub ]] ; then cat ~/.ssh/id_ed25519.pub; else cat ~/.ssh/id_rsa.pub; fi)
$(cloud_init_generate_user_data_for_family ${vm_family})
EOF
}

function wait_for_vm() {
	local vmname="${1}"
	local timeout="${2:-300}"
	local interval=5
	local elapsed=0
	local ip=""

	echo "Waiting for ${vmname} to be ready (guest agent)..."
	while ! $VIRSH domifaddr "${vmname}" --source agent >/dev/null 2>&1
	do
		sleep $interval
		elapsed=$((elapsed + interval))
		if [[ $elapsed -ge $timeout ]]
		then
			break
		fi
	done

	ip=$($VIRSH domifaddr "${vmname}" --source agent 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); if (a[1] != "127.0.0.1") print a[1] }' | head -1)
	if [[ -n "${ip}" ]]; then
		echo "${vmname} is ready, IP: ${ip}"
	else
		echo "ERROR: ${vmname} guest agent did not respond within ${timeout}s" >&2
	fi
}

function ensure_vms() {
	pool_name=${1}
	network_name=${2}
	suffix=$(get_from_config .instances.project)
	# get list of base volumes
	declare -A base_volumes
	for image in $(get_from_config '.storage.images | keys[]')
	do
		base_volumes[${image}]=$(get_from_config .storage.images.${image}.img)
	done
	# iterate over vms
	for vm in $(get_from_config '.instances.vms | keys[]')
	do
		vmname="${vm}-${suffix}"
		if ! $VIRSH dominfo ${vmname} > /dev/null 2>&1
		then
			echo "No such VM: ${vmname}"
			vm_family=$(get_from_config .storage.images.${image}.family)
			provision_volume ${pool_name} ${base_volumes[$(get_from_config '.instances.vms."'${vm}'".type')]} ${vmname} $(get_from_config '.instances.vms."'${vm}'".storage')
			$VIRTINSTALL \
				--name=${vmname} \
				--network "network=${network_name},model=virtio" \
				--import --disk "path=$($VIRSH vol-dumpxml --pool ${pool_name} --vol ${vmname}.qcow2 --xpath '//volume/target/path/text()'),format=qcow2" \
				--hvm --arch x86_64 \
				--channel unix,name=org.qemu.guest_agent.0,mode=bind \
				--osinfo detect=on,require=off \
				--ram=$(get_from_config '.instances.vms."'${vm}'".memory') \
				--vcpus=$(get_from_config '.instances.vms."'${vm}'".cpu') \
				--noautoconsole \
				--cloud-init user-data=<(cloud_init_generate_user_data ${vm_family} ${vm}),network-config=<(cloud_init_generate_network_config),meta-data=<(cloud_init_generate_metadata)
		else
			echo "VM exists: ${vmname}"
		fi
	done
	for vm in $(get_from_config '.instances.vms | keys[]')
	do
		wait_for_vm "${vm}-${suffix}"
	done
}

function get_vm_ip() {
	local vmname="${1}"
	$VIRSH domifaddr "${vmname}" --source agent 2>/dev/null \
		| awk '/ipv4/ { split($4, a, "/"); if (a[1] != "127.0.0.1") print a[1] }' | head -1
}

function generate_ansible_inventory() {
	local suffix=$(get_from_config .instances.project)
	local config_dir=$(dirname "${CONFIG_FILE}")
	local test_count=$(get_from_config '.tests | length')

	for ((i = 0; i < test_count; i++)); do
		local test_type=$(get_from_config ".tests[${i}].type")
		if [[ "${test_type}" != "ansible" ]]; then
			continue
		fi

		local inventory=$(yq ".tests[${i}].inventory" "${CONFIG_FILE}")

		for vm in $(yq -r ".tests[${i}].inventory.all.hosts | keys[]" "${CONFIG_FILE}"); do
			local vmname="${vm}-${suffix}"
			local ip=$(get_vm_ip "${vmname}")
			local vm_user=$(get_from_config '.instances.vms."'"${vm}"'".username')
			if [[ "${vm_user}" == "null" || -z "${vm_user}" ]]; then
				vm_user=$(id -un)
			fi

			inventory=$(echo "${inventory}" | yq \
				".all.hosts.\"${vm}\".ansible_host = \"${ip}\" | .all.hosts.\"${vm}\".ansible_user = \"${vm_user}\"")
		done

		echo "${inventory}" > "${config_dir}/hosts.yaml"
		echo "Ansible inventory written to ${config_dir}/hosts.yaml"
	done
}

function ensure_instances() {
	pool_name=$(get_from_config .storage.pool)
	network_name=$(get_from_config .network.name)
	configure_network ${network_name}
	check_base_images ${pool_name}
	ensure_vms ${pool_name} ${network_name}
	generate_ansible_inventory
}

function clean_up() {
	suffix=$(get_from_config .instances.project)
	for vm in $(get_from_config '.instances.vms | keys[]')
	do
		vmname="${vm}-${suffix}"
		$VIRSH destroy ${vmname} || echo "${vmname} is not running"
		$VIRSH undefine --remove-all-storage ${vmname} || echo "${vmname} is not defined"
	done

}

VIRSH_CONNECTION_STRING=$(get_from_config .uri)
VIRSH="virsh -c ${VIRSH_CONNECTION_STRING}"
VIRTINSTALL="virt-install --connect ${VIRSH_CONNECTION_STRING}"
