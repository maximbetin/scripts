# Cleans evicted pods.
kubectl get pod | grep Evicted | awk '{print $1}' | xargs kubectl delete pod
# Delete errored out pods.
kubectl get pods | grep Error | cut -d' ' -f 1 | xargs kubectl delete pod
# Remove all stopped Docker containers.
docker container rm $(docker container ls –aq)
