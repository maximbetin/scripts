#!/bin/bash

# Endless loop that keeps sending HTTP GET requests to the endpoint every 1 second. If the returned HTTP code is not a 200, displays a warning message. Stop it with CTRL+C.
while :
do
 if [ $(curl -s -o /dev/null -w "%{http_code}" example.com) -ne 200 ]; then
  echo "Site is down!"
 fi
 sleep 1
done
