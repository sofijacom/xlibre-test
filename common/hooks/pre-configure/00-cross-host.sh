#!/bin/sh
# extra/common/hooks/pre-configure/00-cross-host.sh

if [ -n "$XBPS_CROSS_BUILD" ]; then
  # Просто добавляем флаг. xbps-src подхватит CONFIGURE_ARGS автоматически
  CONFIGURE_ARGS="--host=$XBPS_TARGET_MACHINE-linux-gnu $CONFIGURE_ARGS"
fi
