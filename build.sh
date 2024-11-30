#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Get current branch name
BRANCH=$(git rev-parse --abbrev-ref HEAD)

cleanup() {
    echo "Cleaning up containers..."
    docker-compose down
    exit 1
}

# Set up trap to catch failures and clean up
trap cleanup ERR

# Builder name with lnbits prefix
BUILDER_NAME="lnbits-multiarch-builder"

# Function to retry commands
retry() {
    local n=1
    local max=3
    local delay=5
    while true; do
        "$@" && break || {
            if [[ $n -lt $max ]]; then
                ((n++))
                echo "Command failed. Attempt $n/$max:"
                sleep $delay;
            else
                echo "The command has failed after $n attempts."
                return 1
            fi
        }
    done
}

# Remove existing builder if it exists
docker buildx rm ${BUILDER_NAME} 2>/dev/null || true

# Create and use a new builder
docker buildx create --name ${BUILDER_NAME} --use
docker buildx inspect --bootstrap

# Build and push with retries
if [ "$BRANCH" = "main" ]; then
    # On main branch, tag as both main and latest
    retry docker buildx build --platform linux/amd64,linux/arm64 \
      --builder ${BUILDER_NAME} \
      --tag opago/lnbits:latest \
      --tag opago/lnbits:main \
      --push \
      .
else
    # On other branches, tag only with branch name
    retry docker buildx build --platform linux/amd64,linux/arm64 \
      --builder ${BUILDER_NAME} \
      --tag opago/lnbits:$BRANCH \
      --push \
      .
fi

# Start containers
BRANCH=$BRANCH docker-compose up -d

echo "Build and push completed. Container starting now..."
echo "Using branch: $BRANCH"

# Cleanup the builder
docker buildx rm ${BUILDER_NAME}
