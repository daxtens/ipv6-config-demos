#!/bin/bash
set -euo pipefail

NETWORKS="static slaac-rdnss slaac-dhcp6 stful-dhcp6 backend"
MACHINES="backend"
for n in $NETWORKS; do
	MACHINES="$MACHINES $n-ifupdown $n-network-manager $n-networkd $n-router"
done
NETWORKS="$NETWORKS external"
IFUPDOWN_FLAVOUR=16.04
NETPLAN_FLAVOUR=18.04

lxd init --auto --storage-backend=dir || echo "error in lxd init; hoping it's already configured"

delete_networks() {
	for n in $NETWORKS; do
		lxc network delete $n || true
	done
}

delete_machines() {
	for m in $MACHINES; do
		echo "Removing $m"
		lxc delete --force $m || true
	done
}

if [ $# -ge 1 ] && [[ $1 == "--force" ]]; then
	delete_machines
	delete_networks
	shift
fi

if [ $# -ge 1 ] && [[ $1 == "--cleanup" ]]; then
	delete_machines
	delete_networks
	exit
fi

for n in $NETWORKS; do
	if lxc network show $n > /dev/null 2>&1; then
		echo "Network $n already exists!"
		exit 1
	fi
done

# if we specify an address, lxc/d tries to be "helpful" and set up DHCP/DNS
lxc network create backend     ipv6.address=none ipv4.address=none
lxc network create static      ipv6.address=none ipv4.address=none
lxc network create slaac-rdnss ipv6.address=none ipv4.address=none
lxc network create slaac-dhcp6 ipv6.address=none ipv4.address=none
lxc network create stful-dhcp6 ipv6.address=none ipv4.address=none
# we do want ipv4 somewhere so we can install packages
lxc network create external    ipv6.address=none ipv4.address=10.0.6.1/24 ipv4.nat=true

function apt_install() {
	machine=$1
	packages=$2

	lxc network attach external $machine
	lxc exec $machine -- dhclient eth1
	# don't know quite why, but this makes things much faster.
	# they still work without it, it just takes a couple of mins before host works.
	lxc exec $machine -- service systemd-resolved restart
	lxc exec $machine -- sh -c 'while ! host google.com > /dev/null; do echo "Waiting for IPv4 connectivity"; sleep 1; done'

	lxc exec $machine -- apt update
	lxc exec $machine -- apt install -y $packages
	# dhclient release required for xenial/ifupdown to fixup DNS
	# but on systemd-resolved it hangs for about a minute
	# use the presence of ifup to determine if we're on ifupdown
	lxc exec $machine -- time sh -c "which ifup > /dev/null && dhclient -x eth1 || true"
	lxc network detach external $machine
}

# backend: runs a web server and dns server
# for simplicity lets make it a netplan
BACKEND_IP="fd8f:1d7d:b140::1"
lxc launch ubuntu:$NETPLAN_FLAVOUR backend --no-profiles -n backend -s default
apt_install backend bind9
lxc file push backend/named.conf.local backend/etc/bind/named.conf.local
lxc file push backend/db.test backend/etc/bind/db.test
lxc exec backend service bind9 restart
lxc file push backend/60-ipv6.yaml backend/etc/netplan/60-ipv6.yaml
lxc exec backend netplan generate
lxc exec backend netplan apply

function wait_ipv6() {
	machine=$1
	router=$2
	lxc exec $machine -- sh -c "while ! ping6 $router -c 1 > /dev/null; do echo 'Waiting for IPv6 address'; sleep 1; done"
	lxc exec $machine -- sh -c "while ! ping6 $BACKEND_IP -c 1 > /dev/null; do echo 'Waiting for IPv6 routing'; sleep 1; done"
	lxc exec $machine -- sh -c "while ! host ns.test > /dev/null; do echo 'Waiting for IPv6 DNS'; sleep 1; done"
}


# run the tests for a particular type of setup on a particular network
# e.g. launch static networkd "fd8f:1d7d:b141::1"
#         launches static-networkd on the static network, pings b141::1
# e.g. launch slaac-rdnss network-manager "fd8f:1d7d:b142::1"
#         launches slaac-rdnss-network-manager on the slaac-rdnss network, pings b142::1
function launch() {
        network=$1
	flavour=$2
	router=$3
	if [[ $flavour == "ifupdown" ]]; then
		lxc init ubuntu:$IFUPDOWN_FLAVOUR $network-$flavour --no-profiles -n $network -s default
		lxc file push $network-$flavour/eth0-ipv6.cfg $network-$flavour/etc/network/interfaces.d/eth0-ipv6.cfg
		# disable c-i's default: we don't have ipv4 and it will cause drama if we expect it
		echo 'network: {config: disabled}' | lxc file edit $network-$flavour/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
		lxc start $network-$flavour
	else
		lxc launch ubuntu:$NETPLAN_FLAVOUR $network-$flavour --no-profiles -n $network -s default
		lxc file push $network-$flavour/60-ipv6.yaml $network-$flavour/etc/netplan/60-ipv6.yaml
		if [[ $flavour == "network-manager" ]]; then
			apt_install $network-$flavour network-manager
			# wait for the network to come back up
			echo "Waiting for NetworkManager"
			lxc exec $network-$flavour -- service network-manager start ##wth?
			lxc exec $network-$flavour -- sleep 2
			lxc exec $network-$flavour -- nmcli d || true
		fi
		echo "Generating and applying config"
		lxc exec $network-$flavour netplan generate
		lxc exec $network-$flavour netplan apply
		# let it settle
		if [[ $flavour == "network-manager" ]]; then
			# this blocks!
			echo "Waiting for NetworkManager"
			lxc exec $network-$flavour -- nmcli d || true
		fi
	fi
	wait_ipv6 $network-$flavour $router
	# ping router
	lxc exec $network-$flavour -- ping6 $router -c 2
	# ping backend (tests routing)
	lxc exec $network-$flavour -- ping6 $BACKEND_IP -c 2
	# test DNS
	lxc exec $network-$flavour -- host ns.test
}

## static
echo '#################### Static network ####################'
# static-router
lxc launch ubuntu:$NETPLAN_FLAVOUR static-router --no-profiles -n backend -s default
lxc network attach static static-router
lxc file push static-router/60-ipv6.yaml static-router/etc/netplan/60-ipv6.yaml
lxc exec static-router netplan generate
lxc exec static-router netplan apply
lxc exec static-router -- sh -c "echo 1 > /proc/sys/net/ipv6/conf/all/forwarding"
lxc exec static-router -- sh -c "while ! ping6 fd8f:1d7d:b140::1 -c 1 > /dev/null; do echo 'Waiting for IPv6 address'; sleep 1; done"

# static-networkd
launch static networkd "fd8f:1d7d:b141::1"
launch static network-manager "fd8f:1d7d:b141::1"
launch static ifupdown "fd8f:1d7d:b141::1"

## slaac-rdnss
echo '#################### SLAAC + RDNSS network ####################'
# slaac-rdnss-router
lxc launch ubuntu:$NETPLAN_FLAVOUR slaac-rdnss-router --no-profiles -n backend -s default
lxc file push slaac-rdnss-router/radvd.conf slaac-rdnss-router/etc/radvd.conf
apt_install slaac-rdnss-router radvd
lxc network attach slaac-rdnss slaac-rdnss-router
lxc file push slaac-rdnss-router/60-ipv6.yaml slaac-rdnss-router/etc/netplan/60-ipv6.yaml
lxc exec slaac-rdnss-router netplan generate
lxc exec slaac-rdnss-router netplan apply

lxc exec slaac-rdnss-router -- ping6 fd8f:1d7d:b140::1 -c 2
lxc exec slaac-rdnss-router -- sh -c "echo 1 > /proc/sys/net/ipv6/conf/all/forwarding"

# slaac-rdnss-networkd
# this one is a bit complex as we need rdnssd
lxc launch ubuntu:$NETPLAN_FLAVOUR slaac-rdnss-networkd --no-profiles -n slaac-rdnss -s default
apt_install slaac-rdnss-networkd rdnssd
lxc file push slaac-rdnss-networkd/60-ipv6.yaml slaac-rdnss-networkd/etc/netplan/60-ipv6.yaml
lxc exec slaac-rdnss-networkd netplan generate
lxc exec slaac-rdnss-networkd netplan apply
wait_ipv6 slaac-rdnss-networkd "fd8f:1d7d:b142::1"
lxc exec slaac-rdnss-networkd -- ping6 "fd8f:1d7d:b142::1" -c 2
lxc exec slaac-rdnss-networkd -- ping6 $BACKEND_IP -c 2
lxc exec slaac-rdnss-networkd -- host ns.test

# slaac-rdnss network-manager works fine
launch slaac-rdnss network-manager "fd8f:1d7d:b142::1"

# ifupdown also needs rdnssd
lxc init ubuntu:$IFUPDOWN_FLAVOUR slaac-rdnss-ifupdown --no-profiles -n slaac-rdnss -s default
lxc file push slaac-rdnss-ifupdown/eth0-ipv6.cfg slaac-rdnss-ifupdown/etc/network/interfaces.d/eth0-ipv6.cfg
echo 'network: {config: disabled}' | lxc file edit slaac-rdnss-ifupdown/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
lxc start slaac-rdnss-ifupdown
apt_install slaac-rdnss-ifupdown rdnssd
lxc exec slaac-rdnss-ifupdown service networking restart
wait_ipv6 slaac-rdnss-ifupdown "fd8f:1d7d:b142::1"
lxc exec slaac-rdnss-ifupdown -- ping6 "fd8f:1d7d:b142::1" -c 2
lxc exec slaac-rdnss-ifupdown -- ping6 $BACKEND_IP -c 2
lxc exec slaac-rdnss-ifupdown -- host ns.test

## slaac-dhcp6
echo '#################### SLAAC + Stateless DHCPv6 network ####################'
# slaac-dhcp6-router
lxc launch ubuntu:$NETPLAN_FLAVOUR slaac-dhcp6-router --no-profiles -n backend -s default
lxc file push slaac-dhcp6-router/radvd.conf slaac-dhcp6-router/etc/radvd.conf
apt_install slaac-dhcp6-router "radvd isc-dhcp-server"
lxc file push slaac-dhcp6-router/dhcpd6.conf slaac-dhcp6-router/etc/dhcp/dhcpd6.conf
lxc network attach slaac-dhcp6 slaac-dhcp6-router
lxc file push slaac-dhcp6-router/60-ipv6.yaml slaac-dhcp6-router/etc/netplan/60-ipv6.yaml
lxc exec slaac-dhcp6-router netplan generate
lxc exec slaac-dhcp6-router netplan apply
lxc exec slaac-dhcp6-router -- service isc-dhcp-server6 restart

lxc exec slaac-dhcp6-router -- ping6 fd8f:1d7d:b140::1 -c 2
lxc exec slaac-dhcp6-router -- sh -c "echo 1 > /proc/sys/net/ipv6/conf/all/forwarding"

# slaac-dhcp6-networkd
launch slaac-dhcp6 networkd "fd8f:1d7d:b143::1"
launch slaac-dhcp6 network-manager "fd8f:1d7d:b143::1"
launch slaac-dhcp6 ifupdown "fd8f:1d7d:b143::1"

## stful-dhcp6
echo '#################### Stateful DHCPv6 network ####################'
# stful-dhcp6-router
lxc launch ubuntu:$NETPLAN_FLAVOUR stful-dhcp6-router --no-profiles -n backend -s default
lxc file push stful-dhcp6-router/radvd.conf stful-dhcp6-router/etc/radvd.conf
apt_install stful-dhcp6-router "radvd isc-dhcp-server"
lxc file push stful-dhcp6-router/dhcpd6.conf stful-dhcp6-router/etc/dhcp/dhcpd6.conf
lxc network attach stful-dhcp6 stful-dhcp6-router
lxc file push stful-dhcp6-router/60-ipv6.yaml stful-dhcp6-router/etc/netplan/60-ipv6.yaml
lxc exec stful-dhcp6-router netplan generate
lxc exec stful-dhcp6-router netplan apply
lxc exec stful-dhcp6-router -- service isc-dhcp-server6 restart

lxc exec stful-dhcp6-router -- ping6 fd8f:1d7d:b140::1 -c 2
lxc exec stful-dhcp6-router -- sh -c "echo 1 > /proc/sys/net/ipv6/conf/all/forwarding"

# stful-dhcp6-networkd
launch stful-dhcp6 networkd "fd8f:1d7d:b144::1"
launch stful-dhcp6 network-manager "fd8f:1d7d:b144::1"
launch stful-dhcp6 ifupdown "fd8f:1d7d:b144::1"

echo "==================="
echo "Done!"
echo "You can explore any machine with 'lxc exec <machine> -- bash'"
echo "Machines: {static,slaac-rdnss,slaac-dhcp6,stful-dhcp6}-{router,networkd,"
echo "                                                        network-manager,"
echo "                                                        ifupdown},"
echo "          backend"
echo " "
echo "The boxes are not connected to the internet but you can test name resolution"
echo "with 'host ns.test'."
echo " "
echo "lxc list will give you an overview of all assigned addresses."
echo " "
echo "You can clean up with $0 --cleanup"
echo "Or regenerate machines with $0 --force"
echo "Enjoy!"
