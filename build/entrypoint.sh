#!/bin/bash

set -e

echo "  ___      _               ____        _ _     _ "
echo " / _ \  __| | ___   ___   | __ ) _   _(_) | __| |"
echo "| | | |/ _' |/ _ \ / _ \  |  _ \| | | | | |/ _' |"
echo "| |_| | (_| | (_) | (_) | | |_) | |_| | | | (_| |"
echo " \___/ \__,_|\___/ \___/  |____/ \__,_|_|_|\__,_|"
echo
echo "Maintainer: Mint System GmbH <info@mint-system.ch>"

if [ -v PASSWORD_FILE ]; then
    PASSWORD="$(< $PASSWORD_FILE)"
fi

ME=$(basename "$0")
 
entrypoint_log() {
    if [ -z "${ODOO_ENTRYPOINT_QUIET_LOGS:-}" ]; then
        echo "$@"
    fi
}

git_clone_addons() {
    if [ -n "$ADDONS_GIT_REPOS" ]; then
        
        # Setup git ssh key
        mkdir -p ~/.ssh
        if [ -n "$GIT_SSH_PRIVATE_KEY" ]; then
            entrypoint_log "Setup SSH key from env vars."
            echo "$GIT_SSH_PRIVATE_KEY" > ~/.ssh/id_ed25519
            chmod 600 ~/.ssh/id_ed25519
            eval "$(ssh-agent -s)"
            ssh-add ~/.ssh/id_ed25519
        fi

        # Clone git repo addons into /var/lib/odoo/git
        entrypoint_log "Cloning git repos: $ADDONS_GIT_REPOS"
        ADDONS_GIT_REPOS=$(echo "$ADDONS_GIT_REPOS" | tr "," "\n")        
        for ADDON_GIT_REPO in $ADDONS_GIT_REPOS; do
            
            # Supported urls:
            # SSH: git@github.com:OCA/server-tools.git#16.0
            # HTTP: https://github.com/OCA/server-tools.git#16.0

            GIT_URL=$(echo "$ADDON_GIT_REPO" | cut -d# -f1)
            GIT_BRANCH=$(echo "$ADDON_GIT_REPO" | cut -d# -f2)
            GIT_HOSTNAME=$(parse-url "$GIT_URL" hostname)
            GIT_PATH=$(parse-url "$GIT_URL" path | sed 's/.git//g')
            ADDON_PATH="/var/lib/odoo/git/$GIT_HOSTNAME/$GIT_PATH"

            if [ ! -d "$ADDON_PATH/.git" ]; then
                # Clone git repo and submodules
                mkdir -p "$ADDON_PATH"
                ssh-keyscan -t rsa,dsa "$GIT_HOSTNAME" > ~/.ssh/known_hosts 2>/dev/null
                entrypoint_log "$ME: Clone $GIT_URL branch $GIT_BRANCH"
                git clone "$GIT_URL" --depth 1 --single-branch --branch "$GIT_BRANCH" "$ADDON_PATH"
                git -C "$ADDON_PATH" submodule update --init --recursive
            else
                entrypoint_log "$ME: Update $GIT_URL branch $GIT_BRANCH"
                git -C "$ADDON_PATH" switch "$GIT_BRANCH"
                git -C "$ADDON_PATH" pull
                git -C "$ADDON_PATH" submodule update --init --recursive
            fi
            
            # Add git repo to addons path
            if [ -n "$ODOO_ADDONS_PATH" ]; then
                ODOO_ADDONS_PATH="$ODOO_ADDONS_PATH,$ADDON_PATH"
            else
                ODOO_ADDONS_PATH="$ADDON_PATH"
            fi
        done

        # Remove git ssh key
        if [ -n "$GIT_SSH_PRIVATE_KEY" ]; then
            ssh-add -d ~/.ssh/id_ed25519
            rm ~/.ssh/id_ed25519
        fi
    fi
}

git_clone_addons

set_odoo_config_env() {
    if [ -n "$ODOO_ADDONS_PATH" ]; then 

        entrypoint_log "$ME: Resolve addons path: $ODOO_ADDONS_PATH"

        # Search for module manifest files containing "version.+NN.0" and return list of module paths
        ODOO_MODULE_PATH=$(echo "$ODOO_ADDONS_PATH" | tr "," "\n" | xargs -I {} find {} -type f -name "__manifest__.py" | xargs grep -l "version.*${ODOO_VERSION}" | xargs -r dirname | sort -u | tr "\n" ",")
        
        # Set parent folder of module paths as new addons path
        ODOO_MODULE_PATH=$(echo "$ODOO_MODULE_PATH" | tr "," "\n" | xargs -I {} dirname {} | sort -u | tr "\n" "," | sed 's/,$//')

        # Enterprise modules always have version 1.0
        if [[ "$ODOO_ADDONS_PATH" =~ "/mnt/enterprise" ]]; then
            ODOO_ADDONS_PATH="/mnt/enterprise,$ODOO_MODULE_PATH"
        else
            ODOO_ADDONS_PATH="$ODOO_MODULE_PATH"
        fi
    fi
    
    GIT_SSH_PRIVATE_KEY=$(echo -e "$GIT_SSH_PRIVATE_KEY" | base64 -w0)
    export GIT_SSH_PRIVATE_KEY
    export GIT_SSH_PUBLIC_KEY

    : "${ENVIRONMENT:=development}"
    export ENVIRONMENT
    : "${SERVER_WIDE_MODULES:=web}"
    export SERVER_WIDE_MODULES
    : "${PROXY_MODE:=False}"
    export PROXY_MODE
    : "${LOG_LEVEL:=info}"
    export LOG_LEVEL

    : "${LIST_DB:=True}"
    export LIST_DB
    : "${ADMIN_PASSWD:=odoo}"
    export ADMIN_PASSWD
    : "${DBFILTER:=.*}"
    export DBFILTER

    : "${WORKERS:=0}"
    export WORKERS
    : "${LIMIT_REQUEST:=8192}"
    export LIMIT_REQUEST
    : "${LIMIT_TIME_CPU:=60}"
    export LIMIT_TIME_CPU
    : "${LIMIT_TIME_REAL:=120}"
    export LIMIT_TIME_REAL
}

set_odoo_config_env

auto_envsubst() {
    local TEMPLATE_FILE="${ODOO_ENVSUBST_TEMPLATE_FILE:-/etc/odoo/odoo.conf.template}"
    local OUTPUT_FILE="${ODOO_ENVSUBST_OUTPUT_FILE:-/etc/odoo/odoo.conf}"
    local FILTER="${ODOO_ENVSUBST_FILTER:-}"

    DEFINED_ENVS=$(printf '${%s} ' $(awk "END { for (name in ENVIRON) { print ( name ~ /${FILTER}/ ) ? name : \"\" } }" < /dev/null ))

    if [[ -f "$TEMPLATE_FILE" ]]; then
        entrypoint_log "$ME: Running envsubst on $TEMPLATE_FILE to $OUTPUT_FILE"
        envsubst "$DEFINED_ENVS" < "$TEMPLATE_FILE" > "$OUTPUT_FILE"
    fi
}

auto_envsubst

pip_install() {
    if [ -n "$PIP_INSTALL" ]; then
        entrypoint_log "$ME: Install python packages: $PIP_INSTALL"
        pip install --no-cache-dir $(echo "$PIP_INSTALL" | tr "," " ")
    fi

    entrypoint_log "$ME: List python packages:" 
    pip list
}

pip_install

# set the postgres database host, port, user and password according to the environment
# and pass them as arguments to the odoo process if not present in the config file
: ${PGHOST:=${DB_PORT_5432_TCP_ADDR:='db'}}
: ${PGPORT:=${DB_PORT_5432_TCP_PORT:=5432}}
: ${PGUSER:=${DB_ENV_POSTGRES_USER:=${POSTGRES_USER:='odoo'}}}
: ${PGPASSWORD:=${DB_ENV_POSTGRES_PASSWORD:=${POSTGRES_PASSWORD:='odoo'}}}

DB_ARGS=()
function check_config() {
    param="$1"
    value="$2"
    if grep -q -E "^\s*\b${param}\b\s*=" "$ODOO_RC" ; then       
        value=$(grep -E "^\s*\b${param}\b\s*=" "$ODOO_RC" |cut -d " " -f3|sed 's/["\n\r]//g')
    fi;
    DB_ARGS+=("--${param}")
    DB_ARGS+=("${value}")
}
check_config "db_host" "$PGHOST"
check_config "db_port" "$PGPORT"
check_config "db_user" "$PGUSER"
check_config "db_password" "$PGPASSWORD"

init_db() {
    if [ -n "$ODOO_DATABASE" ]; then
        : "${ODOO_INIT:=False}"

        entrypoint_log "$ME: Check if database $ODOO_DATABASE exists"
        wait-for-psql.py ${DB_ARGS[@]} --timeout=30
        DATABASE_EXISTS=$(exec psql "postgres://$PGUSER:$PGPASSWORD@$PGHOST:$PGPORT/postgres" -tAc "SELECT COUNT(*) FROM pg_database WHERE datname = '$ODOO_DATABASE'")

        # If it does not exist, create it
        if [ "$DATABASE_EXISTS" = "0" ]; then
            entrypoint_log "$ME: Create database $ODOO_DATABASE"
            (exec psql "postgres://$PGUSER:$PGPASSWORD@$PGHOST:$PGPORT/postgres" -tAc "CREATE DATABASE $ODOO_DATABASE;") || true
        fi

        entrypoint_log "$ME: Check if database $ODOO_DATABASE is initialized"
        DATABASE_INITIALIZED=$(exec psql "postgres://$PGUSER:$PGPASSWORD@$PGHOST:$PGPORT/$ODOO_DATABASE" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'ir_module_module'")
        
        if [ "$ODOO_INIT" = "True" ] && [ "$DATABASE_INITIALIZED" = "0" ]; then
            : "${ODOO_INIT_LANG:=en_US}"
            : "${ODOO_INIT_ADDONS:=web}"
            entrypoint_log "$ME: Initialize database $ODOO_DATABASE with modules: $ODOO_INIT_ADDONS"
            (exec odoo "${DB_ARGS[@]}" --database "$ODOO_DATABASE" --init "$ODOO_INIT_ADDONS" --config "$ODOO_RC" --stop-after-init --no-http --load-language "$ODOO_INIT_LANG" --without-demo=all) || true
        fi
    fi
}

init_db

click_odoo_update() {
    if [ -n "$ODOO_DATABASE" ]; then
        : "${CLICK_ODOO_UPDATE:=False}"

        if [ "$CLICK_ODOO_UPDATE" = "True" ] && [ -n "$ODOO_ADDONS_PATH" ]; then
            entrypoint_log "$ME: Run click-odoo-update"
            (exec click-odoo-update --addons-path="${ODOO_ADDONS_PATH},${ADDONS_PATH}" -d "$ODOO_DATABASE" ) || true
        fi
    fi
}

click_odoo_update

entrypoint_log "$ME: Running Odoo $ODOO_VERSION as user: $USER"

case "$1" in
    -- | odoo)
        shift
        if [[ "$1" == "scaffold" ]] ; then
            exec odoo "$@"
        else
            wait-for-psql.py ${DB_ARGS[@]} --timeout=30
            exec odoo "$@" "${DB_ARGS[@]}"
        fi
        ;;
    -*)
        wait-for-psql.py ${DB_ARGS[@]} --timeout=30
        exec odoo "$@" "${DB_ARGS[@]}"
        ;;
    *)
        exec "$@"
esac

exit 1
