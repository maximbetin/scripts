#!/usr/bin/env bash

# Script used to migrate/copy CICD variables and their properties based on the selected names (prefixed by KUBECONF_K8S_CLUSTER) and test/prod environment

# Pre-requisites:
# 1. Have jq installed: brew install jq
# 2. Have curl installed: brew install curl
# 3. Set the environment variable $GITLAB_ACCESS_TOKEN

# Functions
usage() {
  echo "Usage: $0 -c cluster_name
  -c Name of the cluster
  -e Test or Prod GitLab environment"
  exit 0
}

# Makes an HTTP GET call and returns the result, handling possible pagination
get_data_from_url() {
  # Get URL from params
  local url=$1

  # Initial value for the results
  results=""

  # $url will be empty if there’s no rel="next" link header
  while [ "$url" ]; do
    # Make an HTTP GET request
    response=$(curl --request GET --include --show-error --silent --header "PRIVATE-TOKEN: $GITLAB_ACCESS_TOKEN" "$url")
    # Extract the HTTP headers
    headers=$(echo "$response" | sed '/^\r$/q')
    # Extract the rel="next" link
    url=$(echo "$headers" | sed -n -E 's/link:.*<(.*?)>; rel="next".*/\1/p')
    # Extract just the response body
    results="$results $(echo "$response" | sed '1,/^\r$/d')"
  done
}

# Makes an HTTP POST/PUT call to create/update a GitLab Group CICD variable
# Since the only difference in the HTTP call to create or to update the GitLab CICD variable is the request method and the URL, we pass them as parameters
set_group_variable() {
  # Get URL from params
  local url=$1
  # Get request method (POST or PUT) from params
  local request_method=$2

  # Get body values from params
  local variable_key=$3
  local variable_value=$4
  local variable_type=$5
  local variable_protected=$6
  local variable_masked=$7
  local variable_scope=$8

  # Make an HTTP POST/PUT request
  response=$(curl --request "$request_method" --include --show-error --silent --header "PRIVATE-TOKEN: $GITLAB_ACCESS_TOKEN" "$url" \
    --form "key=$variable_key" --form "value=$variable_value" --form "variable_type=$variable_type" \
    --form "protected=$variable_protected" --form "masked=$variable_masked" \
    --form "environment_scope=$variable_scope")
}

# Parameters
while getopts 'c:e:' option; do
  case "$option" in
  c) cluster_name=${OPTARG} ;;
  e) gitlab_env=${OPTARG} ;;
  *) usage ;;
  esac
done

# Set the GitLab Group vars based on the selected cluster
if [ "$cluster_name" == "k8s-cluster1" ]; then
  src_gitlab_var_prefix="KUBECONF_K8S_CLUSTER1_"
  dst_gitlab_var_prefix="KUBECONF_K8S_CLUSTER2_"
elif [ "$cluster_name" == "k8s-prod" ]; then
  src_gitlab_var_prefix="KUBECONF_K8S_CLUSTER3_"
  dst_gitlab_var_prefix="KUBECONF_K8S_CLUSTER4_"
else
  echo "Cluster name invalid. Choose either \"-c k8s-prod\" or \"-c k8s-nonprod\""
  exit 1
fi

# Set the GitLab base URL
if [ "$gitlab_env" == "test" ]; then
  gitlab_base_url="https://gitlabtest.com/api/v4/"
elif [ "$gitlab_env" == "prod" ]; then
  gitlab_base_url="https://gitlabprod.com/api/v4/"
else
  echo "GitLab environment invalid. Choose either \"-e test\" or \"-e prod\""
  exit 1
fi

# Create logs folder
mkdir -p logs/"${cluster_name}"

echo "Getting the list of GitLab Group IDs from $gitlab_base_url..."

# Form the URL to retrieve GitLab Groups, 100 is maximum value for per_page
url="${gitlab_base_url}groups?per_page=100"
# Get all GitLab Groups: https://docs.gitlab.com/ee/api/groups.html
get_data_from_url "$url"

# Store the Group IDs in an array
group_ids=($(echo "$results" | jq -r '.[].id'))
# Store the Group URLs in an array
group_urls=($(echo "$results" | jq -r '.[].web_url'))

# Iterate over each Group ID
for ((i = 0; i < ${#group_ids[@]}; i++)); do
  group_id="${group_ids[i]}"
  group_url="${group_urls[i]}"

  # Form the URL to retrieve the Group's CICD variables from the ID, 100 is maximum value for per_page
  url="${gitlab_base_url}groups/$group_id/variables?per_page=100"
  # Get the current Group's CICD variables: https://docs.gitlab.com/ee/api/group_level_variables.html#list-group-variables
  get_data_from_url "$url"

  # If CICD variables found in the Group
  if [ "$results" != " []" ]; then
    echo -e "\nGroup [$group_url]:\n"

    # Get all the CICD variable keys (names)
    variable_keys=$(echo "$results" | jq -r '.[].key')

    # Iterate over each CICD variable key
    for variable_key in $variable_keys; do

      # If the CICD variable key (name) starts with source variable name prefix
      if [[ "$variable_key" =~ ^$src_gitlab_var_prefix ]]; then
        # Form the URL to retrieve the CICD variable's details (from its key)
        url="${gitlab_base_url}groups/$group_id/variables/$variable_key"

        # Obtain the variable's details: https://docs.gitlab.com/ee/api/group_level_variables.html#show-variable-details
        get_data_from_url "$url"

        variable_value=$(echo "$results" | jq -r '.value')
        variable_type=$(echo "$results" | jq -r '.variable_type')
        variable_protected=$(echo "$results" | jq -r '.protected')
        variable_masked=$(echo "$results" | jq -r '.masked')
        variable_scope=$(echo "$results" | jq -r '.environment_scope')

        # Obtain the project's suffix from the CICD variable
        project_suffix=${variable_key#"$src_gitlab_var_prefix"}

        # Form the dst CICD variable name
        dst_variable_name="$dst_gitlab_var_prefix$project_suffix"

        # Form the URL to check if the dst CICD variable key (name) already exists
        url="${gitlab_base_url}groups/$group_id/variables/$dst_variable_name"

        # Obtain the CICD variable's details
        get_data_from_url "$url"

        # If the dst CICD variable name already exists (200 returned), update it
        if [[ "$headers" == *"200"* ]]; then
          echo -n "[$dst_variable_name]: The variable already exists, updating its contents... "

          # Form the URL to update the CICD variable
          url="${gitlab_base_url}groups/$group_id/variables/$dst_variable_name"

          # Update the existing CICD variable (PUT request): https://docs.gitlab.com/ee/api/group_level_variables.html#update-variable
          set_group_variable "$url" "PUT" "$dst_variable_name" "$variable_value" "$variable_type" "$variable_protected" "$variable_masked" "$variable_scope"

          # If HTTP response code was 200 (variable updated)
          if [[ "$response" == *"200"* ]]; then
            echo "Success"
            echo "date=$(date) level=INFO group=${group_url} variable=${dst_variable_name} http_response=${response}" >>logs/"${cluster_name}"/cicd-var-migration.log
          else
            echo "Error"
            echo "date=$(date) level=ERROR group=${group_url} variable=${dst_variable_name} http_response=${response}" >>logs/"${cluster_name}"/cicd-var-migration.log
          fi
        fi
      fi
    done
  fi
done

echo -e "\nDone :)"
