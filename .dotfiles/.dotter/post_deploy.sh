#!/bin/sh
# NOTE: only THIS file gets copied into .dotter/cache/ by Dotter (hooks.rs);
# hooks/link.sh does not, so reference it relative to the repo root (the CWD
# dotter was invoked from), not relative to $0.
exec .dotter/hooks/link.sh deploy
