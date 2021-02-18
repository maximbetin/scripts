# Remove all stopped Docker containers.
docker container rm $(docker container ls –aq)
