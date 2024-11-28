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

# Stop any running containers from this compose file
docker-compose down

# Create and use a new builder that supports multi-platform builds
docker buildx rm multiarch-builder || true
docker buildx create --name multiarch-builder --use || true
docker buildx inspect --bootstrap

# Build and push with retries
if [ "$BRANCH" = "main" ]; then
    # On main branch, tag as both main and latest
    retry docker buildx build --platform linux/amd64,linux/arm64 \
      --builder multiarch-builder \
      --tag opago/lnbits:latest \
      --tag opago/lnbits:main \
      --push \
      .
else
    # On other branches, tag only with branch name
    retry docker buildx build --platform linux/amd64,linux/arm64 \
      --builder multiarch-builder \
      --tag opago/lnbits:$BRANCH \
      --push \
      .
fi

# Only start containers if build and push succeeded
BRANCH=$BRANCH docker-compose up -d

echo "Build and push completed. Container starting now..."
echo "Using branch: $BRANCH"
