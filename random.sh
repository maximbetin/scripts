# Remove all Docker images, stop all Docker containers and remove all Docker containers one-liner
docker stop $(docker ps -a -q) && docker rm $(docker ps -a -q) && docker rmi $(docker images -a -q)

namespace="<namespace>"

# Delete all jobs with failed pods
kubectl delete job --ignore-not-found=true $(kubectl get job -o=jsonpath='{.items[?(@.status.failed)].metadata.name}' -n $namespace) -n $namespace 2>/dev/null || echo -e "No Failed jobs to clean"

# Delete all pods in Error
kubectl get pods -n $namespace | grep Error | awk '{print $1}' | xargs kubectl delete pod -n $namespace 2>/dev/null || echo -e "No Error pods to clean"

# Clean up ReplicaSets
kubectl get rs -n $namespace | awk '$2=="0" && $3=="0" && $4=="0" {print $1}' | xargs -r kubectl delete rs -n $namespace


