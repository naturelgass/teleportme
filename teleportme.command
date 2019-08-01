#!/usr/bin/env bash
#
# Teleportme - An automated always-on FaceTime portal.
# http://papercutsoftware.github.io/teleportme/
#
# Copyright (c) 2014, PaperCut Software http://www.papercut.com/
# Licenced under the MIT - see project's LICENCE file.
#
# Authors:
#   Chris Dance   - https://github.com/codedance/
#   Tim Grimshaw  - https://github.com/squashedbeetle/
#   Alec Clews    - https://github.com/alecthegeek/
#
# Decription: 
#   This script automates FaceTime calls between two endpoints
#   (e.g. offices) during selected time of the day.
#
# Updated for Mojave:
#   Alex Daskalakis - https://github.com/naturelgass/
#
# Important: Make sure that the terminal program you use
#     e.g. Terminal, has permission to control your computer
#     under Security and Privacy preferences.
#
############################################################

#
# Config Section - Edit for your enivornment.
#

# The Apple ID configured on the 'caller' side logged into FaceTime
CALLER_FACETIME_ID=endpoint-a-facetime-id@example.com

# The Mac hostname on the 'caller' side
CALLER_HOSTNAME=portal-endpoint-a

# The Apple ID configured on the 'receiver' side logged into FaceTime
RECEIVER_FACETIME_ID=endpoint-b-facetime-id@example.com

# The Mac hostname on the 'receiver' side
RECEIVER_HOSTNAME=portal-endpoint-b

# Portal open hours in UTC in 24 time.
# This is specified as a list of hours that the portal will be open.
# So "00 23" will mean the portal is open from 23:00 to 00:59 UTC
# NOTE: If using e.g. TextEdit to edit the hours and days, make sure that the ""s around the times do not convert to smart quotes.
# e.g. TextEdit -> Preferences -> Options -> uncheck Smart Quotes
OPEN_UTC_HOURS="22 23"           # values are from 00 to 23
OPEN_UTC_DAYS_OF_WEEK="1 2 3 4 5"   # 0 (Sun) to 6 (Sat)

#
# End Config - If you edit below here, please join us
# on Github!
#

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR_NAME=$(dirname "$0")

usage() {
    echo "${SCRIPT_NAME} [caller|receiver] [alltime]"
    exit 1
}


log() {
    date_time=$(date -u "+%Y-%m-%d %T") # Make log messages have identical times
    echo "${date_time} - $1"            # across machines
}


is_portal_opening_hours() {
    day_of_week=$(date -u '+%w')
    hour_of_day=$(date -u '+%H')

#    if [[ $OPEN_UTC_DAYS_OF_WEEK != *${day_of_week}* ]]; then 
#        return 1 #false
#    fi

#    if [[ $OPEN_UTC_HOURS != *${hour_of_day}* ]]; then 
#        return 1 #false
#    fi
    return 0 #true
}


make_facetime_call() {
    # Open FaceTime with a link to call specified user
    local facetime_user=$1
    open facetime://$facetime_user

    # Click the "Call" button to begin call.
    osascript - << 'EOF'
    tell application "System Events" to tell process "FaceTime"
        -- Wait for FaceTime to prompt user to accept or cancel the call.
        repeat until button "Call" of window "FaceTime" exists
        end repeat

        -- Click the "Call" button to start the call.
        click button "Call" of window "FaceTime"
    end tell
    return
EOF
}


open_facetime() {
    open "/Applications/FaceTime.app"
}


make_fullscreen() {

    # Make full screen if not already
    osascript - << 'EOF'
        tell application "FaceTime" to activate
        delay 1
        tell application "System Events"
            tell process "FaceTime"
                set _fullscreen to value of attribute "AXFullScreen" of window 1
            end tell
        end tell
        if not _fullscreen then
            tell application "System Events"
                keystroke "f" using {command down, control down}
            end tell
            delay 3
        end if
EOF
}


make_landscape() {

    # Make landscape by rotating once
    osascript - << 'EOF'
        tell application "FaceTime" to activate
        delay 1
        tell application "System Events"
            keystroke "r" using command down
        end tell
        delay 3
EOF
}


hide_menubar() {
    # Hack - move the mouse down a bit
    if test -x "${SCRIPT_DIR_NAME}/cliclick"; then
        ${SCRIPT_DIR_NAME}/cliclick "m:-200,200"
    fi
}


is_in_call() {
    status=$(osascript - << 'EOF'
        tell application "FaceTime" to activate
        tell application "System Events"
            tell process "FaceTime"
                set acceptButton to a reference to (button "Accept" of window 1 of application process "NotificationCenter" of application "System Events")
                if acceptButton exists then
                    click acceptButton
                end if
            end tell
        end tell
        tell application "System Events" to tell process "FaceTime"
            try
               if name of front window contains "with" then
                   set output to "running" 
                   copy output to stdout
               end if
            on error err
               log "There is an Incoming call!"
            end try
        end tell
EOF)
    if [[ "$status" = "running" ]] ; then
        return 0
    fi
    return 1
}


loop_while_in_call() {
    while true; do
        sleep 20
        is_in_call || break
        is_portal_opening_hours || break
        make_fullscreen
    done
}


exit_facetime() {
    osascript - << EOF
        tell application "FaceTime" to quit
EOF
    sleep 2
    if pgrep FaceTime; then
        killall FaceTime
    fi
}


setup_auto_accept() {
    #
    # Auto accept calls from remote 
    #
    
    auto_accept=$(defaults read com.apple.FaceTime AutoAcceptInvitesFrom 2>/dev/null)

    if [[ $auto_accept != *${CALLER_FACETIME_ID}* ]] ; then
        log "Adding ${CALLER_FACETIME_ID} to FaceTime auto accept list"
        defaults write com.apple.FaceTime AutoAcceptInvites -bool YES
        defaults write com.apple.FaceTime AutoAcceptInvitesFrom -array-add "$CALLER_FACETIME_ID"    
    fi
}


set_volume() {
    volume=$1
    osascript -e "set Volume ${volume}"
}

#
# Play sound depending on portal state.
#
last_played=
play_sound() {
    if is_portal_opening_hours; then
        if [ -f "${SCRIPT_DIR_NAME}/portal_open.wav" -a "$last_played" != "open" ]; then
            afplay "${SCRIPT_DIR_NAME}/portal_open.wav"
            last_played="open"
        fi
    else
        if [ -f "${SCRIPT_DIR_NAME}/portal_close.wav" -a "$last_played" != "close"  ]; then
            afplay "${SCRIPT_DIR_NAME}/portal_close.wav"
            last_played="close"
        fi
    fi
}

wait_for_network() {
    until ping -c 1 google.com >& /dev/null
    do
        echo Waiting for network to come up...
        sleep 1
    done
}

start_caller() {
    INITIAL_DELAY=20
    retry_delay=${INITIAL_DELAY}
    while true; do
        if is_portal_opening_hours; then
            exit_facetime
            log "Starting call to ${RECEIVER_FACETIME_ID}."
            set_volume 1 
            make_facetime_call ${RECEIVER_FACETIME_ID}
            for (( i=1; i<=10; i++ )); do
                sleep 5
                if is_in_call; then
                    log "Call started. Making full screen."
                    set_volume 10
                    make_fullscreen
                    make_landscape # This should also switch the receiver
                    hide_menubar
                    play_sound
                    retry_delay=${INITIAL_DELAY}
                    break 1
                fi
            done
            loop_while_in_call
            if is_portal_opening_hours; then
                log "Called ended. Retrying in ${retry_delay} seconds..."
                sleep "$retry_delay"
                retry_delay=$(expr $retry_delay '+' 10)
            else
                exit_facetime
                play_sound
                log "Portal closed."
            fi
        else
            log "Idle (portal closed)"
            retry_delay=${INITIAL_DELAY}
            sleep 30
        fi
    done
}


start_receiver() {
    setup_auto_accept
    while true; do
        if is_portal_opening_hours; then
            log "Waiting for call from ${CALLER_FACETIME_ID} to open portal."
            set_volume 1
            play_sound
            exit_facetime
            open_facetime
            # Wait a few min for call and make fullscreen
            for (( i=1; i<=40; i++ )); do
                sleep 5 
                if is_in_call; then
                    log "Call started. Making full screen."
                    set_volume 10
                    make_fullscreen
                    make_landscape
                    hide_menubar
                    break 1
                fi 
            done
            loop_while_in_call
            if is_portal_opening_hours; then
                log "Call not in progress."
            else 
                exit_facetime
                play_sound
                log "Portal closed."
            fi
        else
            log "Idle (portal closed)"
            sleep 30
        fi
    done
}


#
# Main - parse optional args
#

role=caller
hostname=$(hostname)
if [[ "${hostname}" == *${CALLER_HOSTNAME}* ]]; then
    role=caller
fi
if [[ "${hostname}" == *${RECEIVER_HOSTNAME}* ]]; then
    role=receiver
fi

if [[ $# >  0 ]] ; then
    # Arg[1] override for role (for testing)
    case "$1" in 
        caller)
          role=caller
          ;;
        receiver)
          role=receiver
          ;;
        *) usage
    esac
fi

if [[ $# >  1 ]] ; then
    # Arg[2] override for times (for testing)
    case "$2" in
        alltime)
          OPEN_UTC_HOURS="00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23"
          OPEN_UTC_DAYS_OF_WEEK="0 1 2 3 4 5 6"
          ;;
        *) usage
    esac
fi

# Wait for network connection before starting FaceTime.
wait_for_network

if [ "${role}" = "caller" ]; then
    start_caller
else
    start_receiver
fi

# Should never return from start* above.
log "${SCRIPT_NAME} exiting!"
exit 2
