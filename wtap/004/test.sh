#!/bin/sh

# This program requires:
# + wtap - to create/destroy the wtap instances
# + vis_map - to setup the visibility map between wtap instances
# + vimage - to configure/destroy vtap nodes

# The name of the test that will be printed in the begining
TEST_NBR="004"
TEST_NAME="2 nodes and one is PROXY"

# Return value from this test, 0 success failure otherwise
TEST_RESULT=127

# The number of nodes to test
NBR_NODES=2

# The subnet prefix
IP_SUBNET="192.168.2."

cmd()
{
	echo "***${TEST_NBR}*** " $*
	$*
}

info()
{
	echo "***${TEST_NBR}*** " $*
}

descr()
{
	cat <<EOL

This test establishes that the very basic 802.11s PROXY
connectivity works.

It:

* creates two wtap instances
* creates three vimage instances
* creates one wlan vap for each wtap instance and places
  each vap in one of the three vimage instances
* creates one epair and places each end in one
  of two vimage instances
* creates one bridge and places it with a wtap in
  one vimage instance
* sets up the visibility to the following:

             ----MESH-----
  proxyA <--|--> A <-> B  |
             -------------

* does a ping test from each node to each other node.

It is expected that the initial creation and discovery phase
will take some time so the initial run will fail until discovery
is done.  A future extension to the test suite should be to
set lower/upper bounds on the discovery phase time.

EOL
}

setup()
{
	# Initialize output file
	info "TEST: ${TEST_NAME}"
	info `date`

	# Create wtap/vimage nodes
	for i in `seq 1 ${NBR_NODES}`; do
		wtap_if="`expr $i - 1`"
		info "Setup: vimage $i - wtap$wtap_if"
		cmd vimage -c $i
		cmd wtap c $wtap_if
	done
	# Need one more vimage for the PROXY node
	cmd vimage -c 3

	# Set visibility for each node to see the
	# next node.
	n="`expr ${NBR_NODES} - 1`"
	for i in `seq 0 ${n}`; do
		j="`expr ${i} + 1`"
		cmd vis_map a $i $j
		cmd vis_map a $j $i
	done

	# Makes the visibility map plugin deliver packets to resp. dest.
	cmd vis_map o

	# Create and setup PROXY node with corresponding bridge
	cmd ifconfig epair0 create
	cmd ifconfig epair0a vnet 1
	cmd ifconfig epair0b vnet 2
	cmd ifconfig bridge0 create
	# Disables bridge filtering
	cmd sysctl net.link.bridge.pfil_member=0
	cmd sysctl net.link.bridge.pfil_bridge=0
	cmd ifconfig bridge0 vnet 2	

	# Create each wlan subinterface, place into the correct vnet
	for i in `seq 0 ${n}`; do
		vnet="`expr ${i} + 2`"
		cmd ifconfig wlan${i} create wlandev wtap${i} wlanmode mesh
		cmd ifconfig wlan${i} meshid mymesh
		cmd wlandebug -i wlan${i} hwmp
		cmd ifconfig wlan${i} vnet ${vnet}
	done

	# Bring all interfaces up.
	# NB: Bridge need to be brought up before the bridged interfaces
	cmd jexec 1 ifconfig epair0a inet 192.168.2.1
	cmd jexec 2 ifconfig bridge0 addm epair0b addm wlan0 up
	cmd jexec 2 ifconfig epair0b up
	cmd jexec 2 ifconfig wlan0 up
	cmd jexec 2 ifconfig wlan0 inet ${IP_SUBNET}2
	cmd jexec 3 ifconfig wlan1 up
	cmd jexec 3 ifconfig wlan1 inet ${IP_SUBNET}3
}

run()
{
	NBR_TESTS=0 NBR_FAIL=0

	# Number of all nodes in this test
	ALL_NODES=`expr ${NBR_NODES} + 1`
	# Test connectivity from each node to each other node
	for i in `seq 1 ${ALL_NODES}`; do
		for j in `seq 1 ${ALL_NODES}`; do
			if [ "$i" != "$j" ]; then
				# From vimage '$i' to vimage '$j'..
				info "Checking ${i} -> ${j}.."
				NBR_TESTS="`expr ${NBR_TESTS} + 1`"
				# Return after a single successful packet
				cmd jexec $i ping -q -t 5 -c 5 \
				    -o ${IP_SUBNET}${j}

				if [ "$?" = "0" ]; then
					info "CHECK: ${i} -> ${j}: SUCCESS"
				else
					info "CHECK: ${i} -> ${j}: FAILURE"
					NBR_FAIL="`expr ${NBR_FAIL} + 1`"
				fi
			fi
		done
	done
	if [ $NBR_FAIL = 0 ]; then
		info "ALL TESTS PASSED"
		TEST_RESULT=0
	else
		info "FAILED ${NBR_FAIL} of ${NBR_TESTS} TESTS"
	fi
}

teardown()
{
	cmd vis_map c
	# Unlink all links
	# XXX: this is a limitation of the current plugin,
	# no way to reset vis_map without unload wtap.
	n="`expr ${NBR_NODES} - 1`"
	for i in `seq 0 ${n}`; do
		j="`expr ${i} + 1`"
		cmd vis_map d $i $j
		cmd vis_map d $j $i
	done
	cmd jexec 2 ifconfig bridge0 destroy
	# Bring epair back to host view, we bring both back
	# otherwise a panic occurs, ie one is not enough.
	cmd ifconfig epair0a -vnet 1
	cmd ifconfig epair0b -vnet 2
	cmd ifconfig epair0a destroy
	n="`expr ${NBR_NODES} - 1`"
	for i in `seq 0 ${n}`; do
		vnet="`expr ${i} + 2`"
		cmd jexec ${vnet} ifconfig wlan${i} destroy
	done
	for i in `seq 1 ${NBR_NODES}`; do
		wtap_if="`expr $i - 1`"
		cmd wtap d ${wtap_if}
		cmd vimage -d ${i}
	done
	cmd vimage -d 3
	exit ${TEST_RESULT}
}

EXEC_SETUP=0
EXEC_RUN=0
EXEC_TEARDOWN=0
while [ "$#" -gt "0" ]
do
	case $1 in
		'all')
			EXEC_SETUP=1
			EXEC_RUN=1
			EXEC_TEARDOWN=1
		;;
		'setup')
			EXEC_SETUP=1
		;;
		'run')
			EXEC_RUN=1
		;;
		'teardown')
			EXEC_TEARDOWN=1
		;;
		'descr')
			descr
			exit 0
		;;
                *)
			echo "$0 {all | setup | run | teardown | descr}"
			exit 127
		;;
        esac
        shift
done

if [ $EXEC_SETUP = 1 ]; then
	setup
fi
if [ $EXEC_RUN = 1 ]; then
	run
fi
if [ $EXEC_TEARDOWN = 1 ]; then
	teardown
fi

exit 0

