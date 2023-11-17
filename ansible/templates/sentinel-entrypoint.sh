#!/bin/bash

CONF="$1"
REDIS_CLUSTER_NAME="$2"
REDIS_PORT="$3"
SENTINEL_PORT="$4"
REDIS_SENTINEL_QUORUM="$5"
REDIS_SENTINEL_REPLICATION_FACTOR="$6"
REDIS_SERVER_REPLICATION_FACTOR="$7"

if [ -z "$CONF" ] || [ ! -w "$CONF" ] ||
   [ -z "$REDIS_CLUSTER_NAME" ] ||
   [ -z "$REDIS_PORT" ] || [ $REDIS_PORT -le 0 ] ||
   [ -z "$SENTINEL_PORT" ] || [ $SENTINEL_PORT -le 0 ] ||
   [ -z "$REDIS_SENTINEL_QUORUM" ] || [ $REDIS_SENTINEL_QUORUM -le 0 ] || 
   [ -z "$REDIS_SENTINEL_REPLICATION_FACTOR" ] || [ $REDIS_SENTINEL_REPLICATION_FACTOR -le 0 ] ||
   [ -z "$REDIS_SERVER_REPLICATION_FACTOR" ] || [ $REDIS_SERVER_REPLICATION_FACTOR -le 0 ]; then
    echo "Usage: $0 <path to sentinel.conf> <cluster name> <server port> <sentinel port> <sentinel quorum> <sentinel replication factor> <server replication factor>" >&2
    echo "sentinel.conf file must exist and must be writable" >&2
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


function wait_for_sentinel_quorum() {
    echo "Waiting for cluster quorum: minimum of $REDIS_SENTINEL_QUORUM sentinels must be online" >&2
    while true; do
        # Get sentinel addresses in sentinel_addrs array
        get_sentinel_addrs
        if [ ${#sentinel_addrs[@]} -lt $REDIS_SENTINEL_QUORUM ]; then
            sleep 1
        else
            break
        fi
    done
}


function get_master_addr_from_sentinel() {
    sentinel_addr=$1

    echo "Querying sentinel $sentinel_addr for redis master address" >&2
    master_addr=$(redis-cli -h $sentinel_addr -p $SENTINEL_PORT SENTINEL GET-MASTER-ADDR-BY-NAME $REDIS_CLUSTER_NAME |grep '^1')
    if [ ! -z "$master_addr" ]; then
        echo "Sentinel $sentinel_addr supplied redis master address $master_addr" >&2
    else
        echo "Could not get master address from sentinel $sentinel_addr - cluster might be not initialized yet" >&2
    fi

    echo "$master_addr"
}


function get_master_addr_from_dns_lowest() {
    echo "Waiting for at least one redis server to come online" >&2
    while [ -z "$master_addr" ]; do
        for ((i=1; i<=$REDIS_SERVER_REPLICATION_FACTOR; i++)); do
            master_addr=$(getent hosts redis-server-$i |awk '{ print $2 }' |sort -n |head -1)
            echo "Querying DNS about redis-server-$i: '$master_addr'" >&2
            if [ ! -z "$master_addr" ]; then
                break
            fi
        done
        sleep 1
    done

    echo "$master_addr"
}


this_container_ip=$(grep $(hostname) /etc/hosts |sed -r 's|\s.*||' |tr -d '\n')
if [ $? -ne 0 ] || [ -z "$this_container_ip" ]; then
    echo "Failed to determine container IP address" >&2
    exit 1
fi


get_sentinel_addrs
for sentinel_addr in ${sentinel_addrs[@]}; do
    if [ $sentinel_addr != $(hostname) ]; then
        master_addr=$(get_master_addr_from_sentinel $sentinel_addr)
        if [ -z "$master_addr" ]; then
            sleep 1
        else
            break
        fi
    fi
done

if [ -z "$master_addr" ]; then
    wait_for_sentinel_quorum
    echo "Going to use the lowest redis server address as master" >&2
    sleep 1
    master_addr=$(get_master_addr_from_dns_lowest)
fi
echo "Using redis master address $master_addr" >&2

sed -r -e "s|(sentinel monitor $REDIS_CLUSTER_NAME) [a-zA-Z0-9\.\-]+ ($REDIS_PORT [0-9]+)|\1 $master_addr \2|g" -i "$CONF"
if [ $? -ne 0 ]; then
    echo "Failed to subsitute master address in '$CONF'" >&2
    exit 1
fi

sed -r -e "s|(sentinel announce-ip) [a-zA-Z0-9\.\-]+|\1 $(hostname)|g" -i "$CONF"
if [ $? -ne 0 ]; then
    echo "Failed to subsitute container hostname in '$CONF'" >&2
    exit 1
fi

echo "Starting sentinel with the following config:" >&2
cat "$CONF" >&2

exec /usr/local/bin/redis-server "$CONF" --sentinel
