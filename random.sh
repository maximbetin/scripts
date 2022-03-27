# Remove all Docker images, stop all Docker containers and remove all Docker containers one-liner
docker rmi $(docker images -a -q) && docker stop $(docker ps -a -q) && docker rm $(docker ps -a -q)
