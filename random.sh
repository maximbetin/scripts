# Cleans evicted pods.
kubectl get pod | grep Evicted | awk '{print $1}' | xargs kubectl delete pod
# Delete errored out pods.
kubectl get pods | grep Error | cut -d' ' -f 1 | xargs kubectl delete pod
# Remove all stopped Docker containers.
docker container rm $(docker container ls –aq)
# Drain node pools one by one
for node in $(kubectl get node | grep SchedulingDisabled | cut -d " " -f1)
do
    echo kubectl drain $node
    kubectl drain $node --force --delete-emptydir-data --ignore-daemonsets
    sleep 600
done
