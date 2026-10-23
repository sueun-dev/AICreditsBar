#!/bin/bash
# Shared by build/install: only stop this checkout's installed app, never a
# throwaway test binary or an app from another checkout with the same name.
stop_app() {
    local binary="$1" pid command directory stopped=1
    directory="$(cd "$(dirname "$binary")" 2>/dev/null && pwd -P)" || return 1
    binary="$directory/$(basename "$binary")"
    for pid in $(pgrep -x aicreditsbar || true); do
        command="$(ps -ww -p "$pid" -o comm=)" || continue
        if [[ "$command" != /* ]]; then
            directory="$(/usr/sbin/lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
            [ -n "$directory" ] || continue
            command="$directory/$command"
        fi
        directory="$(cd "$(dirname "$command")" 2>/dev/null && pwd -P)" || continue
        command="$directory/$(basename "$command")"
        [ "$command" = "$binary" ] || continue
        if kill -TERM "$pid" 2>/dev/null; then stopped=0; fi
    done
    return "$stopped"
}
