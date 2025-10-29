# Delete errored out pods.
kubectl get pods | grep Error | cut -d' ' -f 1 | xargs kubectl delete pod
