#!/bin/bash
set -euo pipefail

# non-amd64 untested!
ARCH=`arch`
if [[ $ARCH == 'x86_64' ]]; then
    ARCH='amd64'
fi

# we need a recent LXD, so use Artful
echo "Downloading the latest Artful image"
uvt-simplestreams-libvirt sync release=artful arch=$ARCH

echo "Cleaning up old VM if it exists"
uvt-kvm destroy ipv6-test || true

echo "Creating vm"
# each LXC guest uses about 0.8GB (!!)
# we create 17.
uvt-kvm create ipv6-test release=artful arch=$ARCH --memory=2048 --disk=20

uvt-kvm wait ipv6-test
echo "Copying files"
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o CheckHostIP=no -r * ubuntu@$(uvt-kvm ip ipv6-test): > /dev/null

echo " "
echo "Entering ssh: use ./test.sh to run the test!"
uvt-kvm ssh --insecure ipv6-test
