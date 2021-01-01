#!/usr/bin/env bashio
set -x
# init vars
CONFIG_PATH=/data/options.json
DISABLE_TLS="$(bashio::config 'disable_tls')"
UNSAFE_SAVE_INI="$(bashio::config 'unsafe_auto_init')"
VAULT_ADMIN_USER="$(bashio::config 'vault_admin_user')"
VAULT_ADMIN_PASSWORD="$(bashio::config 'vault_admin_password')"
CREATE_ADMIN_USER="$(bashio::config 'create_admin_user')"
AUTO_PROVISION="$(bashio::config 'auto_provision')"
PROVISION_TOKEN="$(bashio::config 'provision_token')"
PGP_KEYS="$(bashio::config 'pgp_keys')"
INI_PATH="/data/vault/vault.ini"
ASC_PATH="/data/vault/adm.asc"
GNUPGHOME="/data/vault/gpghome"
VAULT_TOKEN=""
output=""
export GNUPGHOME

if [ ! -d $GNUPGHOME ]; then
    mkdir -p $GNUPGHOME
fi

if [ ! -d /config/vault/terraform ]; then
    mkdir -p /config/vault/terraform
fi

if [ "$DISABLE_TLS" = 'false' ]; then
    scheme="https://"
    export VAULT_SKIP_VERIFY=1
else
    scheme="http://"
fi
export VAULT_ADDR="${scheme}localhost:8200"

generate_gpg_key() {
    GNUPGHOME="/data/vault/gpghome"
    output=""
    export GNUPGHOME
    mkdir -p $GNUPGHOME 2>/null || true
    chmod 700 $GNUPGHOME
    if [ ! "$(gpg --list-keys operator@vault.local)" ]; then
        cat >initkey <<EOF
%echo Generating a basic OpenPGP key
Key-Type: RSA
Key-Length: 2048
Subkey-Type: default
Subkey-Length: 2048
Name-Real: Adm
Name-Comment: No passphrase
Name-Email: operator@vault.local
Expire-Date: 0
Passphrase: passphrase
# Do a commit here, so that we can later print "done" :-)
%commit
%echo done
EOF
        gpg --batch --generate-key initkey
        gpg --armor --export operator@vault.local >$ASC_PATH
    fi
}

wait_ready() {
    bashio::log.info "Waiting for vault to be ready"
    while [ -z "$(vault status -format json 2>/dev/null)" ]; do
        sleep 3
    done
}

decrypt_root() {
    bashio::log.info "In Decrypt root"
    gpg --list-keys
    gpg --list-secret-keys
    sleep 30
    echo $output | jq -r .root_token | base64 -d >/tmp/$$.gpg
    echo "passphrase" | gpg --passphrase-fd=0 -no-tty --decrypt /tmp/$$.gpg
    sleep 30
}

decrypt() {
    gpg --list-keys
    echo $output | jq --arg v $1 -r '.[$v] | .[]' | base64 -d >/tmp/$$.gpg
    echo "passphrase" | gpg --passphrase-fd=0 --no-tty --decrypt /tmp/$$.gpg
}

# initialized
wait_initialized() {
    if [ "$(vault status -format json | jq .initialized)" = "false" ]; then
        bashio::log.info "Initializing the vault"
        output="$(vault operator init -format json -pgp-keys "${ASC_PATH}" -root-token-pgp-key "${ASC_PATH}" -key-shares=1 -key-threshold=1)"
        if [ "$UNSAFE_SAVE_INI" = "true" ]; then
            echo "$output" >$INI_PATH
        fi
        if ! decrypt_root ; then
            bashio::log.error "Can't initialized : exiting (sleep 60s)"
            sleep 60
            exit 1
        fi
    else
        bashio::log.info "Vault already initialized"
        if [ -f $INI_PATH ]; then
            output=$(cat $INI_PATH)
            if [ -z "$output" ]; then
                bashio::log.error "* no ini file : exiting (sleep 60s)"
                sleep 60
                exit 1
            fi
        fi
    fi
}

# migrated
wait_migrated() {
    if [ "$(vault status -format json | jq .migration)" = "true" ]; then
        bashio::log.info "Migrating"
        for a in $(decrypt unseal_keys_b64); do
            vault operator unseal -migrate "$a" >/dev/null
        done
        if [ "$(vault status -format json | jq .initialized)" = "false" ]; then
            bashio::log.error "Migration failed : exiting (sleep 60s)"
            sleep 60
            exit 1
        else
            bashio::log.info "Migration done"
        fi
    fi
}

# unsealed
wait_unsealed() {
    bashio::log.info "Wait unsealead"
    local keys=""
    if [ "$(vault status -format json | jq .sealed)" = "true" ]; then
        bashio::log.info "Vault is sealed"

        keys=$(decrypt unseal_keys_b64)
        if [ -n "$keys" ]; then
            bashio::log.info "We have keys, unsealing vault"
            for a in $(decrypt unseal_keys_b64); do
                vault operator unseal "$a" >/dev/null
            done
            if [ "$(vault status -format json | jq .sealed)" = "true" ]; then
                bashio::log.error "Unseal failed : exiting (sleep 60)"
                sleep 60
                exit 1
            else
                bashio::log.info "Unseal done"
            fi
        else
            bashio::log.info "We wait until its manually (or auto) unsealed"
            while [ "$(vault status -format json | jq .sealed)" = "true" ]; do
                sleep 5
            done
        fi
    else
        bashio::log.info "Vault already unsealed"
    fi
}

# root token available
wait_root_token() {
    if decrypt_root; then
        bashio::log.info "Root token available"
    else
        bashio::log.error "* root token unavailable, exiting (sleep 60)"
        sleep 60
        exit 1
    fi
}

terraform_vault() {
    bashio::log.info "Applying terraform"
    if [ ! -f /config/vault/terraform/vault.tf.template ]; then
        cp -a /vault/terraform/vault.tf.template /config/vault/terraform/vault.tf.template
    fi
    if [ ! -d /data/vault/terraform ]; then
        mkdir /data/vault/terraform
    fi
    /usr/bin/tempio -conf $CONFIG_PATH -template /config/vault/terraform/vault.tf.template -out /data/vault/terraform/vault.tf
    if [ -z "$VAULT_TOKEN" ]; then
        if [ -n "$PROVISION_TOKEN" ]; then
            bashio::log.info "Using config provision token"
            VAULT_TOKEN=$PROVISION_TOKEN
            export VAULT_TOKEN
        else
            bashio::log.error "No provision token no terraform"
            return
        fi
    else
        bashio::log.info "We have a vault token"
    fi
    cd /data/vault/terraform || return
    terraform init
    terraform apply -auto-approve
}

admin_user() {
    if [ "$CREATE_ADMIN_USER" = "true" ]; then
        bashio::log.info "Creating user ${VAULT_ADMIN_USER}"
        vault write "auth/userpass/users/${VAULT_ADMIN_USER}" password="${VAULT_ADMIN_PASSWORD}" policies=super-admin
    else
        if [ -n "${VAULT_ADMIN_USER}" ]; then
            bashio::log.info "Deleting user ${VAULT_ADMIN_USER}" #fixme me yeah it won't work if the user change in the meantime
            vault delete "auth/userpass/users/${VAULT_ADMIN_USER}"
        fi
    fi
}

vault_rekey() {
    bashio::log.warning "Starting vault rekey"
    vault operator rekey -cancel 2>/dev/null >/dev/null || true
    nonce=$(vault operator rekey -format json -pgp-keys "${PGP_KEYS}" -key-shares=1 -key-threshold=1 -init | jq .nonce -r)
    for unseal_key in $(decrypt unseal_keys_b64); do
        answer=$(vault operator rekey -format json -nonce "$nonce" "$unseal_key")
        vault_answer=$(echo "$answer" | jq .keys_base64)
        if [ "$vault_answer" != "null" ]; then
            bashio::log.info "Rekeying done"
            echo "$answer" >/data/vault/vault-ini.json
            return
        fi
    done
    bashio::log.error "Rekeying failed, exiting (sleep 60)"
    sleep 60
    exit 1
}

vault_retoken() {
    bashio::log.warning "Starting vault retoken"
    vault operator generate-root -cancel 2>/dev/null >/dev/null || true
    nonce=$(vault operator generate-root -format json -pgp-key "${PGP_KEYS}" -init | jq .nonce -r)
    # we use unseal keys to do the retoken
    for unseal_key in $(decrypt unseal_keys_b64); do
        answer=$(vault operator generate-root -format json -nonce "$nonce" "$unseal_key")
        vault_answer=$(echo "$answer" | jq -r .encoded_root_token)
        complete=$(echo "$answer" | jq -r .complete)
        if [ "$vault_answer" != "" ] && [ "$complete" = "true" ]; then
            bashio::log.info "New root token created, saving it"
            echo "$answer" >/data/vault/vault-ini-token.json
            bashio::log.warning "Revoke old token"
            VAULT_TOKEN="$(echo "$output" | jq -r .root_token)"
            export VAULT_TOKEN
            vault token revoke "$VAULT_TOKEN"
            # unset token it won't work anymore
            VAULT_TOKEN=""
            # delete the file it won't work anymore
            rm $INI_PATH
            return
        fi
    done
    bashio::log.error "Rekeying failed, exiting (sleep 60)"
    sleep 60
    exit 1
}

main() {
    # start by creating a gpg key if there's none already
    generate_gpg_key

    # wait for vault to listen
    wait_ready

    # unsafe auto unseal mode
    if [ "$UNSAFE_SAVE_INI" = "true" ] && [ "$PGP_KEYS" = "null" ]; then
        wait_initialized
        wait_migrated
        wait_unsealed
        wait_root_token
        VAULT_TOKEN="$(decrypt_root)"
        export VAULT_TOKEN
        bashio::log.info "Wait 15 seconds (raft election)"
        sleep 15
    fi

    # pgp manual unseal key mode
    if [ ! "$PGP_KEYS" = "null" ]; then
        if [ "$(vault status -format json | jq .initialized)" = "false" ]; then
            # not initialized doing it
            vault operator init -format json -pgp-keys "${PGP_KEYS}" -root-token-pgp-key "${PGP_KEYS}" -key-shares=1 -key-threshold=1 >/data/vault/vault-ini.json
            # fixme check output
        else
            # already init
            if [ -f /data/vault/vault-ini.json ]; then
                # we have a config file (fixme check if it works)
                bashio::log.info "Already initialized, found vault-ini, nothing to do"
            else
                # migrating from auto unseal
                bashio::log.warning "Already initialized, but no vault-ini found, try migrating"
                wait_initialized
                wait_unsealed
                # wait election (fixme get status)
                bashio::log.info "Wait for the raft election (15s)"
                sleep 15
                # we rekey here
                vault_retoken
                vault_rekey
            fi
        fi
        # show encrypted tokens for manual usage
        bashio::log.info "unseal keys and root token should be in /data/vault/vault-ini.json and  /data/vault/vault-ini-token.json (encrypted for $PGP_KEYS) :"
        if [ -f /data/vault/vault-ini.json ]; then
            bashio::log.notice "$(cat /data/vault/vault-ini.json 2>/dev/null)"
        fi
        if [ -f /data/vault/vault-ini-token.json ]; then
            bashio::log.notice "$(cat /data/vault/vault-ini-token.json 2>/dev/null)"
        fi
    fi

    # apply terraform and default admin user
    if [ "$AUTO_PROVISION" = "true" ]; then
        wait_initialized
        wait_unsealed
        terraform_vault
        admin_user
    fi

    # inifinite loop
    bashio::log.info "Finished: Enter infinite loop."
    while true; do
        sleep 1200
    done
}
main "$@"
