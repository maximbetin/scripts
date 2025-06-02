#!/bin/bash

# Keep checking the uptime of the site every 1 second. If the site is down, display a warning message.
while :
do
  if [ $(curl -s -o /dev/null -w "%{http_code}" https://www.google.com) -ne 200 ]; then
    echo "Site is down!"
  fi
  sleep 1
done
