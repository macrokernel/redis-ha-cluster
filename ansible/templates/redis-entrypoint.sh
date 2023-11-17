#!/bin/bash

CONF="$1"
REDIS_CLUSTER_NAME="$2"
REDIS_PORT="$3"
SENTINEL_PORT="$4"
REDIS_SENTINEL_REPLICATION_FACTOR="$5"

if [ -z "$CONF" ] || [ ! -r "$CONF" ] ||
   [ -z "$REDIS_CLUSTER_NAME" ] || 
   [ -z "$REDIS_PORT" ] || [ $REDIS_PORT -le 0 ] ||
   [ -z "$SENTINEL_PORT" ] || [ $SENTINEL_PORT -le 0 ] || 
   [ -z "$REDIS_SENTINEL_REPLICATION_FACTOR" ] || [ $REDIS_SENTINEL_REPLICATION_FACTOR -le 0 ]; then
    echo "Usage: $0 <path to redis.conf> <cluster name> <server port> <sentinel port> <sentinel replication factor>" >&2
    echo "redis.conf file must exist and must be writable" >&2
    exit 1
fi


function get_sentinel_addrs() {
    sentinel_addrs=()
    for ((i=1; i<=$REDIS_SENTINEL_REPLICATION_FACTOR; i++)); do
        if getent hosts "redis-sentinel-$i" >/dev/null 2>&1; then
            sentinel_addrs+=("redis-sentinel-$i")
        fi
    done
    if [ ${#sentinel_addrs[@]} -gt 0 ]; then
        echo -n "Sentinels:" >&2
        printf ' %s' "${sentinel_addrs[@]}" >&2
        echo >&2
    fi
}


function get_master_addr_from_sentinel() {
    sentinel_addr=$1

    echo "Querying sentinel $sentinel_addr for redis master address" >&2
    master_addr=$(redis-cli -h $sentinel_addr -p $SENTINEL_PORT SENTINEL GET-MASTER-ADDR-BY-NAME $REDIS_CLUSTER_NAME |head -1)
    if [ ! -z "$master_addr" ]; then
        echo "Sentinel $sentinel_addr supplied redis master address $master_addr" >&2
    fi

    echo "$master_addr"
}


this_container_ip=$(grep $(hostname) /etc/hosts |sed -r 's|\s.*||' |tr -d '\n')
if [ $? -ne 0 ] || [ -z "$this_container_ip" ]; then
    echo "Failed to determine container IP address" >&2
    exit 1
fi


while true; do
    get_sentinel_addrs
    for sentinel_addr in ${sentinel_addrs[@]}; do
        master_addr=$(get_master_addr_from_sentinel $sentinel_addr)
        if [ -z "$master_addr" ]; then
            sleep 1
        else
            break
        fi
    done
    if [ -z "$master_addr" ]; then
        sleep 1
    else
        break
    fi
done

sed -r -e "s|(replica-announce-ip) [a-zA-Z0-9\.\-]+|\1 $(hostname)|g" -i "$CONF"
if [ $? -ne 0 ]; then
    echo "Failed to subsitute container hostname in '$CONF'" >&2
    exit 1
fi

if [ "$master_addr" == "$(hostname)" ] || [ "$master_addr" == "$this_container_ip" ]; then
    echo "Starting redis server $(hostname) ($this_container_ip) as a master" >&2
    exec /usr/local/bin/redis-server $CONF
else
    echo "Starting redis server $(hostname) ($this_container_ip) as a replica of $master_addr" >&2
    exec /usr/local/bin/redis-server $CONF --slaveof $master_addr $REDIS_PORT 
fi
