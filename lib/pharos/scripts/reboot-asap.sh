#!/bin/bash

# To allow some time for ssh client to disconnect before the shutdown throws the user  out,
# this script calls shutdown -r with an argument.
#
# Since the precision of the time argument of shutdown is 1 minute, this script tries to either:
# - Use the next HH:MM if it isn't too close already
# - Use "1" (one minute)
#
# The script finally outputs the number of seconds left before the shutdown
sec=$(date +%S)
tl=""

if [[ "$sec" -lt "56" ]]; then
  tl=$((60-$sec))
  minute=$(date +%M | sed 's/^0//')
  ((minute++))
  hour=$(date +%k)
  if [[ "$minute" -eq "60" ]]; then
    minute="0"
    ((hour++))
  fi
  ts=$(printf "%02d:%02d\\n" "$hour" "$minute")
else
  ts="+1"
  tl="60"
fi

shutdown -r "$ts"
echo "$tl"
