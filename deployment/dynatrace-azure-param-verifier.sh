#!/bin/bash

#Will it work? Who knows.
tdnf install -y curl

readonly DYNATRACE_TARGET_URL_REGEX="^(https?:\/\/[-a-zA-Z0-9@:%._+~=]{1,255}\/?)(\/e\/[a-z0-9-]{36}\/?)?$"
readonly ACTIVE_GATE_TARGET_URL_REGEX="^https:\/\/[-a-zA-Z0-9@:%._+~=]{1,255}\/e\/[-a-z0-9]{1,36}[\/]{0,1}$"
readonly DEPLOYMENT_NAME_REGEX="^[a-z0-9]{3,20}$"
readonly EVENT_HUB_CONNECTION_STRING_REGEX="^Endpoint=sb:\/\/.*EntityPath=[^[:space:]]+$"
readonly FILTER_CONFIG_REGEX="([^;\s].+?)=([^;]*)"
#readonly TAGS_REGEX="^([^<>,%&\?\/]+?:[^,]+,?)+$"

check_arg() {
  CLI_ARGUMENT_NAME=$1
  ARGUMENT=$2
  REGEX=$3
  if [ -z "$ARGUMENT" ]; then
    echo "No $CLI_ARGUMENT_NAME"
    exit 1
  else
    if ! [[ "$ARGUMENT" =~ $REGEX ]]; then
      echo "Not correct $CLI_ARGUMENT_NAME, pattern is: $REGEX"
      exit 1
    fi
  fi
}

#check_arg --deployment-name "$DEPLOYMENT_NAME" "$DEPLOYMENT_NAME_REGEX"
#check_arg --resource-group "$RESOURCE_GROUP" ".+"
if [[ "$ENABLE_USER_ASSIGNED_MANAGED_IDENTITY" == "false" ]] || [[ -z "$ENABLE_USER_ASSIGNED_MANAGED_IDENTITY" ]]; then 
  check_arg --event-hub-connection-string "$EVENT_HUB_CONNECTION_STRING" "$EVENT_HUB_CONNECTION_STRING_REGEX"
fi

if [ -n "$FILTER_CONFIG" ]; then check_arg --filter-config "$FILTER_CONFIG" "$FILTER_CONFIG_REGEX";fi
#if [ -n "$TAGS" ]; then check_arg --tags "$TAGS" "$TAGS_REGEX"; fi