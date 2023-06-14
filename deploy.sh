#!/bin/bash -e
set -e
set -o noglob

# Default Values
BUILD_ID=""
NAMESPACE=""
CONTAINER_REGISTRY="" ## Name of container registry including hostname
REPO="" ## name of repo for registry, ie $CONTAINER_REGISTRY.azurecr.io/$REPO:$BUILD_ID
SUBSCRIPTION_ID="" ## Used for Azure to set subscription
REGION=""
REPLICA_COUNT="3" ## Set amount of replicas for the k8 deployment\
RESOURCE_GROUP="" ## Used for Azure for resource group

# optional with defaults
MAINTENANCE_WINDOW=1 ## deploy using a maintenance window. Command will use drush on the current site to enable maintenance mode, run deploy, then disable maintenance when done
DELETE_CRON=1
GOVCLOUD=0
debug_level=0

# script set (ie, not set from arguments)
CURRENT_DIRECTORY=$(echo "${PWD}")
IMAGE_ID="" ## result of $CONTAINER_REGISTRY/$REPO:$BUILD_ID but only set after those variables are set
DRUPAL_POD=""
AZURE=0
AWS=0

# --- helper functions for logs ---
debug() {
    if [ $debug_level -ge 1 ]; then
        echo '[DEBUG] ' "$@"
    fi
}
info() {
    if [ $debug_level -ge 0 ]; then
        echo '[INFO] ' "$@"
    fi
}
warn() {
    echo '[WARN] ' "$@" >&2
}
fatal() {
    echo '[ERROR] ' "$@" >&2
    exit 1
}

azure_govcloud() {
	az cloud set --name AzureUSGovernment

}

azure_authenticate() {
	az account set --subscription $SUBSCRIPTION_ID

}

azure_cr_authenticate() {
	if [ $GOVCLOUD -eq 1 ]; then
		azure_govcloud

	fi

	REGISTRY_NAME=$(echo "$CONTAINER_REGISTRY" | cut -d '.' -f 1)

	az acr login -n $REGISTRY_NAME

}

azure_generate_kubeconfig() {
	az aks get-credentials --resource-group $RESOURCE_GROUP --name aks-$NAMESPACE --public-fqdn

}

# --- build image ----
# build() {
	

# }

# --- set IMAGE_ID variable ----
generate_image_tag() {
	IMAGE_ID=$CONTAINER_REGISTRY/$REPO:$BUILD_ID

	info "image_id: ${IMAGE_ID}"

}

# --- Push built image to container registry ----
push() {
	info "tagging image: drupal-${BUILD_ID} as ${IMAGE_ID}"
	# retag prebuilt image
	
	docker image tag drupal-$BUILD_ID $IMAGE_ID

	# push to repo
	info "pushing image: ${IMAGE_ID}"
	docker push $IMAGE_ID

}

get_drupal_pod() {
	DRUPAL_POD=$(kubectl get pods -l app=drupal -n $NAMESPACE --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')

}

deploy() {
	if [ $AZURE -eq 1 ]; then
		azure_authenticate
		azure_generate_kubeconfig
	
	fi

	generate_image_tag

	# deploy configmap
	kubectl apply -f $CURRENT_DIRECTORY/.kubernetes/configmap-$NAMESPACE.yaml

	if [ $DELETE_CRON -eq 1 ]; then
		kubectl delete --ignore-not-found cronjob drupal-cron -n $NAMESPACE

	fi

	# put site into maintenance mode for length of deployment
	if [ $MAINTENANCE_WINDOW -eq 1 ]; then
		get_drupal_pod
		kubectl exec "$DRUPAL_POD" -n $NAMESPACE -- bash -c "drush state:set system.maintenance_mode 1 --input-format=integer"

	fi

	# Deploy Drupal
	export NAMESPACE=$NAMESPACE
	export IMAGE_ID=$IMAGE_ID
	export REPLICA_COUNT=$REPLICA_COUNT

	envsubst '$NAMESPACE,$IMAGE_ID,$REPLICA_COUNT' < $CURRENT_DIRECTORY/.kubernetes/deployment.yaml | kubectl apply -f -

	# Wait 5 to ensure the new replica set has been deployed out
	sleep 5
	kubectl rollout status deployments/drupal -n $NAMESPACE

	# set DRUPAL_POD to one of the newest pods so we can run post deploy steps against it
	get_drupal_pod

	# run post deploy scripts
	kubectl exec "$DRUPAL_POD" -n $NAMESPACE -- bash -c "drush deploy"

	# lift maintenance mode
	if [ $MAINTENANCE_WINDOW -eq 1 ]; then
		get_drupal_pod
		kubectl exec "$DRUPAL_POD" -n $NAMESPACE -- bash -c "vendor/bin/drush state:set system.maintenance_mode 0 --input-format=integer"

	fi

	# if we removed cron, we need to add it back in
	if [ $DELETE_CRON -eq 1 ]; then
		envsubst '$NAMESPACE,$IMAGE_ID' < $CURRENT_DIRECTORY/.kubernetes/crons.yaml | kubectl apply -f -

	fi

	unset NAMESPACE IMAGE_ID REPLICA_COUNT

}

# --- helper function that combines build and push into one ----
push_image() {
	if [ $AZURE -eq 1 ]; then
		azure_authenticate
		azure_cr_authenticate
		
	fi

	generate_image_tag
	push

}

# --- exec ----
entrypoint() {
	# Array to store missing arguments
	missing_args=()

	# Extract the command
	command="$1"
	shift

	# Process command-line arguments
	for arg in "$@"; do
		case $arg in
			--build-id=*) BUILD_ID="${arg#*=}" ;;
			--namespace=*) NAMESPACE="${arg#*=}" ;;
			--container-registry=*) CONTAINER_REGISTRY="${arg#*=}" ;;
			--repo=*) REPO="${arg#*=}" ;;
			--subscription-id=*) SUBSCRIPTION_ID="${arg#*=}" ;;
			--resource-group=*) RESOURCE_GROUP="${arg#*=}" ;;
			--region=*) REGION="${arg#*=}" ;;
			--maintenance-window=*) MAINTENANCE_WINDOW="${arg#*=}" ;;
			--delete-cron=*) DELETE_CRON="${arg#*=}" ;;
			--replica-count=*) REPLICA_COUNT="${arg#*=}" ;;
			--govcloud=*) GOVCLOUD="${arg#*=}" ;;
			-v|--v)
				debug_level=$((debug_level + 1))
				shift
				;;
			*) echo "Invalid argument: $arg" ;;
		esac
	done

	# output all commands if debug level is great enough
	if [ $debug_level -ge 1 ]; then
		set -o xtrace
	fi

	# Output arguments for debugging purposes
	for arg in "$@"; do
		info "Argument: $arg"
	done

	# set appropriate cloud environment based on arguments provided
	if [ -n "$SUBSCRIPTION_ID" ] && [ "$SUBSCRIPTION_ID" != "" ]; then
		AZURE=1
	fi

	if [ -n "$REGION" ] && [ "$REGION" != "" ]; then
		AWS=1
	fi

	# Check for required arguments based on the command
	case $command in
		push)
			# Check for required arguments
			if [ -z "$BUILD_ID" ]; then missing_args+=("--build-id"); fi
			if [ -z "$NAMESPACE" ]; then missing_args+=("--namespace"); fi
			if [ -z "$CONTAINER_REGISTRY" ]; then missing_args+=("--container-registry"); fi
			if [ -z "$REPO" ]; then missing_args+=("--repo"); fi
			if [ -z "$SUBSCRIPTION_ID" ]; then missing_args+=("--subscription-id"); fi

			# Execute function if missing_args is empty
			if [ ${#missing_args[@]} -eq 0 ]; then push_image; fi

		;;
		deploy)
			# Check for required arguments
			if [ -z "$BUILD_ID" ]; then missing_args+=("--build-id"); fi
			if [ -z "$NAMESPACE" ]; then missing_args+=("--namespace"); fi
			if [ -z "$CONTAINER_REGISTRY" ]; then missing_args+=("--container-registry"); fi
			if [ -z "$REPO" ]; then missing_args+=("--repo"); fi
			if [ -z "$SUBSCRIPTION_ID" ]; then missing_args+=("--subscription-id"); fi
			if [ -z "$RESOURCE_GROUP" ]; then missing_args+=("--resource-group"); fi

			# Execute function if missing_args is empty
			if [ ${#missing_args[@]} -eq 0 ]; then deploy; fi

		;;
		*)
			echo "Invalid command: $command"
			exit 1
		;;
	esac

	# Check if any missing arguments exist
	if [ ${#missing_args[@]} -gt 0 ]; then
		fatal "Missing required argument(s) for command '$command': ${missing_args[*]}"
	fi

}

{
	entrypoint "$@"
}