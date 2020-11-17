#!/bin/bash

# Infinite loop that keeps sending curl HTTP requests to the endpoint every 1 second. If the returned HTTP code is not 200, displays a warning message.

while :
do
	if [ $(curl -s -o /dev/null -w "%{http_code}" example.com) -ne 200 ]; then
		echo "Site is down!"
	fi
	sleep 1
done
