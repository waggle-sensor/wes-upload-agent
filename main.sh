#!/bin/bash -e

. common.sh

if [ -z "$WAGGLE_NODE_ID" ]; then
    fatal "WAGGLE_NODE_ID is not defined"
fi

if [ -z "$WAGGLE_BEEHIVE_UPLOAD_HOST" ]; then
    fatal "WAGGLE_BEEHIVE_UPLOAD_HOST is not defined"
fi

if [ -z "$WAGGLE_BEEHIVE_UPLOAD_PORT" ]; then
    fatal "WAGGLE_BEEHIVE_UPLOAD_PORT is not defined"
fi

mkdir -p /root/.ssh/

SSH_CA_PUBKEY="${SSH_CA_PUBKEY:-/etc/waggle/ca.pub}"
SSH_KEY="${SSH_KEY:-/etc/waggle/ssh-key}"
SSH_CERT="${SSH_CERT:-/etc/waggle/ssh-key-cert.pub}"

echo "using credentials"
echo "ssh ca pubkey: ${SSH_CA_PUBKEY}"
echo "ssh key: ${SSH_KEY}"
echo "ssh cert: ${SSH_CERT}"

# get username from ssh cert
# TODO(sean) make this match more robust. output looks like:
# /etc/waggle/ssh-key-cert.pub:
#         Type: ssh-rsa-cert-v01@openssh.com user certificate
#         Public key: RSA-CERT SHA256:i5Orb/PHT1rM7Mq6mM/m366tnPVaIzGXDr0Ras9PRbE
#         Signing CA: RSA SHA256:XxSyeGs55EKetdO+31XLgz/fGbAk7v/S57ChRPhibgo (using rsa-sha2-256)
#         Key ID: "node-0000000000000001 ssh host key"
#         Serial: 0
#         Valid: from 2021-03-22T21:09:04 to 2022-03-22T21:14:04
#         Principals: 
#                 node-0000000000000001
#         Critical Options: (none)
#         Extensions: 
#                 permit-X11-forwarding
#                 permit-agent-forwarding
#                 permit-port-forwarding
#                 permit-pty
#                 permit-user-rc
username=$(ssh-keygen -L -f "${SSH_CERT}" | awk '$1 ~ /^node-/ {print $1}')
echo "using username ${username}"

# define ssh config
cat <<EOF > /root/.ssh/config
Host beehive-upload-server
    Port ${WAGGLE_BEEHIVE_UPLOAD_PORT}
    User ${username}
    IdentityFile ${SSH_KEY}
    CertificateFile ${SSH_CERT}
    BatchMode yes
    ConnectTimeout 30
    LogLevel VERBOSE
EOF

# NOTE workaround for "Host key verification failed" issue. at the moment, this seems to be because
# our upload server ssh cert uses name "beehive-upload-server". eventually, this should be updated
# to use the actual hostname of the upload server.

# create backup of original /etc/hosts file
# NOTE used by the resolve_upload_server_and_update_etc_hosts function below.
cp /etc/hosts /tmp/hosts

resolve_upload_server_and_update_etc_hosts() {
    if ! hostip=$(resolve_host_ip "$WAGGLE_BEEHIVE_UPLOAD_HOST"); then
        echo "unable to resolve host ip for $WAGGLE_BEEHIVE_UPLOAD_HOST"
        return 1
    fi

    echo "resolved $WAGGLE_BEEHIVE_UPLOAD_HOST to $hostip"

    if ! cat /tmp/hosts > /etc/hosts; then
        echo "failed to update /etc/hosts"
        return 1
    fi
    
    if ! echo "$hostip beehive-upload-server" >> /etc/hosts; then
        echo "failed to update /etc/hosts"
        return 1
    fi

    if ! echo "@cert-authority beehive-upload-server $(cat ${SSH_CA_PUBKEY})" > /root/.ssh/known_hosts; then
        echo "failed to update /root/.ssh/known_hosts"
        return 1
    fi
}

rsync_upload_files() {
    upload_list="$1"

    if [ -z "${upload_list}" ]; then
        echo "must provide upload list"
        return 1
    fi

    rsync -av \
        --exclude '.tmp*' \
        --files-from="${upload_list}" \
        --remove-source-files \
        --partial-dir=.partial/ \
        --bwlimit=0 \
        "/uploads/" \
        "beehive-upload-server:~/uploads/"
    # TODO investigate this option more. was using previously but
    # not clear what it's doing. also don't want it to accidentally
    # attempt to remove dir shared by plugin pod.
    # --prune-empty-dirs
}

build_upload_list() {
    # group up to 100 data files or 1000 dirs in one upload batch
    (
        cd /uploads
    find . | awk -F/ '
        # ignore tmp dirs
        /.tmp/ {next}
        # bail out if we reach 1000 dirs or 100 data items
        (numdirs == 1000) || ((numdata == 100) && !/data/ && !/meta/) {exit}
        # increment totals
        NF == 4 {numdirs++}
        /data/ {numdata++}
        {print}
    '
    )
}

upload_files() {
    echo "building upload batch list"
    if ! build_upload_list > /tmp/upload_list; then
        fatal "failed to build upload batch list"
    fi

    echo "doing pre rsync clean up"
    awk -F/ 'NF == 4' /tmp/upload_list | xargs -n 100 rmdir --ignore-fail-on-non-empty || true

    # check if there are any files to upload *before* connecting and
    # authenticating with the server
    if ! grep -q -m1 data /tmp/upload_list; then
        echo "no data files to rsync"
        return 0
    fi

    echo "resolving upload server address"
    if ! resolve_upload_server_and_update_etc_hosts; then
        fatal "failed to resolve upload server and update /etc/hosts."
    fi

    echo "rsyncing files"
    if ! rsync_upload_files /tmp/upload_list; then
        echo "failed to rsync files"
        return 1
    fi

    echo "doing post rsync clean up"
    awk -F/ 'NF == 4' /tmp/upload_list | xargs -n 100 rmdir --ignore-fail-on-non-empty || true
}

while true; do
    if upload_files; then
        touch /tmp/healthy
    fi
    sleep 3
done
