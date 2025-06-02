#!/bin/bash

# Cleans evicted pods.
kubectl get pod | grep Evicted | awk '{print $1}' | xargs kubectl delete pod

# Delete errored out pods.
kubectl get pods | grep Error | cut -d' ' -f 1 | xargs kubectl delete pod

# Gets all K8S defined resources, creates a folder for each and moves them into the corresponding folder.
for n in $(kubectl get -o=name pvc, configmap, serviceaccount, secret, ingress, service, deployment, statefulset, hpa, job, cronjob); do
  mkdir -p $(dirname $n)
  kubectl get -o=yaml $n >$n.yaml
done

# Drain node pools one by one
for node in $(kubectl get node | grep SchedulingDisabled | cut -d " " -f1); do
  echo kubectl drain $node
  kubectl drain $node --force --delete-emptydir-data --ignore-daemonsets
  sleep 600
done
