#!/bin/sh

if [ "$1" = 'redis-cluster' ]; then
    # Allow passing in cluster IP by argument or environmental variable
    IP="${2:-$IP}"

    if [ -z "$IP" ]; then # If IP is unset then discover it
        IP=$(hostname -I)
    fi

    echo " -- IP Before trim: '$IP'"
    IP=$(echo ${IP}) # trim whitespaces
    echo " -- IP Before split: '$IP'"
    IP=${IP%% *} # use the first ip
    echo " -- IP After trim: '$IP'"

    if [ -z "$INITIAL_PORT" ]; then # Default to port 7000
      INITIAL_PORT=7000
    fi

    if [ -z "$MASTERS" ]; then # Default to 3 masters
      MASTERS=3
    fi

    if [ -z "$SLAVES_PER_MASTER" ]; then # Default to 1 slave for each master
      SLAVES_PER_MASTER=1
    fi

    if [ -z "$BIND_ADDRESS" ]; then # Default to any IPv4 address
      BIND_ADDRESS=0.0.0.0
    fi

    max_port=$(($INITIAL_PORT + $MASTERS * ( $SLAVES_PER_MASTER  + 1 ) - 1))
    first_standalone=$(($max_port + 1))
    if [ "$STANDALONE" = "true" ]; then
      STANDALONE=2
    fi
    if [ ! -z "$STANDALONE" ]; then
      max_port=$(($max_port + $STANDALONE))
    fi

    for port in $(seq $INITIAL_PORT $max_port); do
      mkdir -p /redis-conf/${port}
      mkdir -p /redis-data/${port}

      if [ -e /redis-data/${port}/nodes.conf ]; then
        rm /redis-data/${port}/nodes.conf
      fi

      if [ -e /redis-data/${port}/dump.rdb ]; then
        rm /redis-data/${port}/dump.rdb
      fi

      if [ -e /redis-data/${port}/appendonly.aof ]; then
        rm /redis-data/${port}/appendonly.aof
      fi

      if [ "$port" -lt "$first_standalone" ]; then
        IP=${IP} PORT=${port} BIND_ADDRESS=${BIND_ADDRESS} envsubst < /redis-conf/redis-cluster.tmpl > /redis-conf/${port}/redis.conf
        nodes="$nodes $IP:$port"
      else
        IP=${IP} PORT=${port} BIND_ADDRESS=${BIND_ADDRESS} envsubst < /redis-conf/redis.tmpl > /redis-conf/${port}/redis.conf
      fi

      if [ ! -z "$REDIS_PASSWORD" ]; then
        echo " -- Setting Redis password"
        echo "requirepass ${REDIS_PASSWORD}" >> /redis-conf/${port}/redis.conf
        echo "masterauth ${REDIS_PASSWORD}" >> /redis-conf/${port}/redis.conf
      fi

      if [ "$port" -lt $(($INITIAL_PORT + $MASTERS)) ]; then
        if [ "$SENTINEL" = "true" ]; then
          PORT=${port} SENTINEL_PORT=$((port - 2000)) envsubst < /redis-conf/sentinel.tmpl > /redis-conf/sentinel-${port}.conf
          cat /redis-conf/sentinel-${port}.conf
        fi
      fi

    done

    bash /generate-supervisor-conf.sh $INITIAL_PORT $max_port > /etc/supervisor/supervisord.conf

    supervisord -c /etc/supervisor/supervisord.conf
    cat /etc/supervisor/supervisord.conf
    sleep 3

    #
    ## Check the version of redis-cli and if we run on a redis server below 5.0
    ## If it is below 5.0 then we use the redis-trib.rb to build the cluster
    #
    echo "Using redis-cli to create the cluster ${nodes}"

    if [ ! -z "$REDIS_PASSWORD" ]; then
        redis-cli -a ${REDIS_PASSWORD} --cluster create --cluster-replicas $SLAVES_PER_MASTER $nodes --cluster-yes
    else
        redis-cli --cluster create --cluster-replicas $SLAVES_PER_MASTER $nodes --cluster-yes
    fi

    if [ "$SENTINEL" = "true" ]; then
      for port in $(seq $INITIAL_PORT $(($INITIAL_PORT + $MASTERS))); do
        redis-sentinel /redis-conf/sentinel-${port}.conf &
      done
    fi

    tail -f /var/log/supervisor/redis*.log
else
  exec "$@"
fi
