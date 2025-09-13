#!/usr/bin/env bash 

for DIR in ./beegfs/stor_01_tgt_101 ./beegfs/stor_01_tgt_102 ./beegfs/nfs-exports; do
    if [ ! -d "$DIR" ]; then
        echo "$(date) INFO [setup.sh]: Creating directory $DIR"
        mkdir -p "$DIR"
    else
        echo "$(date) INFO [setup.sh]: Directory $DIR already exists"
    fi
done

