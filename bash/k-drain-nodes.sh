# Drain node pools one by one
for node in $(kubectl get node | grep SchedulingDisabled | cut -d " " -f1); do
    echo "Draining node: $node"
    kubectl drain $node --force --delete-emptydir-data --ignore-daemonsets
    sleep 600
done
