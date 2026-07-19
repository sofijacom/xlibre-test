#!/bin/sh
# extra/common/hooks/pre-configure/00-cross-host.sh

if [ -n "$XBPS_CROSS_BUILD" ]; then
    export CONFIGURE_ARGS="--host=$XBPS_TARGET_MACHINE-linux-gnu $CONFIGURE_ARGS"
fi
