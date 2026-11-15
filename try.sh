#!/usr/bin/env bash
# One launch attempt. Needs env: C (compartment OCID), AD, SUBNET, IMAGE, SSH_PUB.
# Exits 0 if the instance exists or was created. Non-zero means "no capacity, try later".
set -u
n=$(oci compute instance list -c "$C" --display-name forever-free \
  --query 'length(data[?"lifecycle-state"!=`TERMINATED`])' --raw-output) || exit 1
[ "$n" != 0 ] && { echo "instance already exists"; exit 0; }
oci compute instance launch -c "$C" --availability-domain "$AD" \
  --shape VM.Standard.A1.Flex --shape-config '{"ocpus":1,"memoryInGBs":12}' \
  --subnet-id "$SUBNET" --image-id "$IMAGE" --display-name forever-free \
  --assign-public-ip true --boot-volume-size-in-gbs 150 \
  --ssh-authorized-keys-file <(echo "$SSH_PUB")
