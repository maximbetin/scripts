# Remove all Docker images, stop all Docker containers and remove all Docker containers one-liner
docker rmi $(docker images -a -q) && docker stop $(docker ps -a -q) && docker rm $(docker ps -a -q)

# Delete all jobs with failed pods
kubectl delete job --ignore-not-found=true $(kubectl get job -o=jsonpath='{.items[?(@.status.failed)].metadata.name}' -n <namespace>) -n <namespace>

# Delete all pods in Error
kubectl get pods -n <namespace> | grep Error | awk '{print $1}' | xargs kubectl delete pod -n <namespace>
