#!/bin/bash

# Gets all K8S defined resources, creates a folder for each and moves them into the corresponding folder.

for n in $(kubectl get -o=name pvc, configmap, serviceaccount, secret, ingress, service, deployment, statefulset, hpa, job, cronjob)
do
    mkdir -p $(dirname $n)
    kubectl get -o=yaml $n > $n.yaml
done
