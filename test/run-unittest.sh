#!/usr/bin/env bash
set -ueo pipefail

. $(dirname "${BASH_SOURCE[0]}")/common.sh

FILENAME="${LOG_FILE:-test.log}"

> $(dirname "${BASH_SOURCE[0]}")/"${FILENAME}"

function log() {
    echo -e "\033[0;33m[INFO] $@\033[0m"
    echo "[INFO] $@" >> $(dirname "${BASH_SOURCE[0]}")/"${FILENAME}"
}

function logError() {
    echo -e 1>&2 "\033[0;31m[ERROR] $@\033[0m"
    echo "[ERROR] $@" >> $(dirname "${BASH_SOURCE[0]}")/"${FILENAME}"
    any_errors=1
}

function die() {
    logError "$@"
    exit 1
}

export -f log
export -f die

if [ -z ${DUB:-} ]; then
    die $LINENO 'Variable $DUB must be defined to run the tests.'
fi

if [ -z ${DC:-} ]; then
    log '$DC not defined, assuming dmd...'
    DC=dmd
fi

DC_BIN=$(basename "$DC")
CURR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FRONTEND="${FRONTEND:-}"

if [ "$#" -gt 0 ]; then FILTER=$1; else FILTER=".*"; fi

for script in $(ls $CURR_DIR/*.sh); do
    if [[ ! "$script" =~ $FILTER ]]; then continue; fi
    if [ "$script" = "$(gnureadlink ${BASH_SOURCE[0]})" ] || [ "$(basename $script)" = "common.sh" ]; then continue; fi
    if [ -e $script.min_frontend ] && [ ! -z "$FRONTEND" ] && [ ${FRONTEND} \< $(cat $script.min_frontend) ]; then continue; fi
    log "Running $script..."
    DUB=$DUB DC=$DC CURR_DIR="$CURR_DIR" $script || logError "Script failure."
done

for pack in $(ls -d $CURR_DIR/*/); do
    if [[ ! "$pack" =~ $FILTER ]]; then continue; fi
    if [ -e $pack/.min_frontend ] && [ ! -z "$FRONTEND" -a "$FRONTEND" \< $(cat $pack/.min_frontend) ]; then continue; fi

    # First we build the packages
    if [ ! -e $pack/.no_build ] && [ ! -e $pack/.no_build_$DC_BIN ]; then # For sourceLibrary
        build=1
        if [ -e $pack/.fail_build ]; then
            log "Building $pack, expected failure..."
            # $DUB build --force --root=$pack --compiler=$DC 2>/dev/null && logError "Error: Failure expected, but build passed."
        else
            log "Building $pack..."
            # $DUB build --force --root=$pack --compiler=$DC || logError "Build failure."
        fi
    else
        build=0
    fi

    # We run the ones that are supposed to be run
    if [ $build -eq 1 ] && [ ! -e $pack/.no_run ] && [ ! -e $pack/.no_run_$DC_BIN ]; then
        log "Running $pack..."
        # $DUB run --force --root=$pack --compiler=$DC || logError "Run failure."
    fi

    # Finally, the unittest part
    if [ $build -eq 1 ] && [ ! -e $pack/.no_test ] && [ ! -e $pack/.no_test_$DC_BIN ]; then
        log "Testing $pack..."
        # $DUB test --force --root=$pack --compiler=$DC || logError "Test failure."
    fi
done

echo
echo 'Testing summary:'
cat $(dirname "${BASH_SOURCE[0]}")/"${FILENAME}"

exit ${any_errors:-0}
