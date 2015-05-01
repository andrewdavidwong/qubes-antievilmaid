#!/bin/bash
#
# Anti Evil Maid for dracut by Invisible Things Lab
# Copyright (C) 2010 Joanna Rutkowska <joanna@invisiblethingslab.com>
#
# Mount our device, read the sealed secret blobs, initialize TPM
# and finally try to unseal the secrets and display them to the user
#

DEV=/dev/antievilmaid
MNT=/antievilmaid
TPM_DIR=/var/lib/tpm
SYSTEM_PS=$MNT/antievilmaid/system.data
SEALED_SECRET=$MNT/antievilmaid/sealed_secret.blob
UNSEALED_SECRET=/tmp/unsealed-secret
PLYMOUTH_THEME_UNSEALED_SECRET=/usr/share/plymouth/themes/qubes-dark/antievilmaid_secret.png


export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"
. /lib/dracut-lib.sh


# work with or without plymouth

shopt -s expand_aliases
PLYMOUTH_MESSAGES=()
if plymouth --ping 2>/dev/null; then
    alias plymouth_active=true
    function message() {
        plymouth message --text="$*"
        PLYMOUTH_MESSAGES+=("$*")
    }
else
    alias plymouth=:
    alias plymouth_active=false
    alias message=echo
fi


# mount the AEM device and setup TPM

if [ -d "$MNT" ] ; then
    info "$MNT already exists, skipping..."
    exit 0
fi

info "Waiting for antievilmaid boot device to become available..."
while ! [ -b "$DEV" ]; do
    sleep 0.1
done

info "Mounting the antievilmaid boot device..."
mkdir "$MNT"
mount "$DEV" "$MNT" || exit 1

info "Initializing TPM..."
modprobe tpm_tis
ip link set dev lo up
mkdir -p "$TPM_DIR"
cp "$SYSTEM_PS" "$TPM_DIR" || exit 1
tcsd

if [ -f "$SEALED_SECRET" ] ; then
    TPM_ARGS="-o $UNSEALED_SECRET"
    if ! getarg rd.antievilmaid.asksrkpass; then
        info "Using default TPM SRK unseal password"
        TPM_ARGS="$TPM_ARGS -z"
    fi

    message "Attempting to unseal the secret from the TPM..."

    UNSEAL_CMD="tpm_unsealdata $TPM_ARGS -i $SEALED_SECRET"
    # we try only once as some TCG 1.2 TPMs start "protecting themselves against
    # dictionary attacks" when there's more than 1 try within a short time... -_-
    # (TCG 2 fixes that):
    if plymouth_active && getarg rd.antievilmaid.asksrkpass; then
        plymouth ask-for-password --command="$UNSEAL_CMD" \
                                  --prompt="TPM SRK unseal password" \
                                  --number-of-tries=1
    else
        $UNSEAL_CMD  # has its own prompt when needed ("Enter SRK password:")
    fi
else
    message "No data to unseal. Do not forget to generate a ${SEALED_SECRET##*/}"
fi

info "Unmounting the antievilmaid device..."
umount "$MNT"


# display the secret in the next (.png) or the current dialog (.txt)

if getarg rd.antievilmaid.png_secret; then
    # Verify if the unsealed PNG secret seems valid and replace the lock icon
    if file "$UNSEALED_SECRET" 2>/dev/null | grep -q PNG; then
        cp "$UNSEALED_SECRET" "$PLYMOUTH_THEME_UNSEALED_SECRET"
    fi

    WHERE="next to the prompt for it"
else
    message ""
    message "$(cat "$UNSEALED_SECRET" 2>/dev/null)"
    message ""

    WHERE="above"
fi
message "Never enter your disk password unless the secret $WHERE is correct!"

plymouth pause-progress
if getarg rd.antievilmaid.dontforcestickremoval; then
    if ! getarg rd.antievilmaid.png_secret; then
        message "Press <SPACE> to continue..."
        plymouth watch-keystroke --keys=" "
    fi
else
    message "Remove your Anti Evil Maid stick to continue..."
    while [ -b "$DEV" ]; do
        sleep 0.1
    done
fi
plymouth unpause-progress

if ! getarg rd.antievilmaid.dontforcestickremoval || ! getarg rd.antievilmaid.png_secret; then
    for m in "${PLYMOUTH_MESSAGES[@]}"; do
        plymouth hide-message --text="$m"
    done
fi
rm -f "$UNSEALED_SECRET"
