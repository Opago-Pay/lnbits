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

# Function to wait for LNbits and get superuser
get_superuser() {
    local max_attempts=12
    local attempt=1
    local superuser=""
    
    echo "Waiting for LNbits to initialize..."
    while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt of $max_attempts..."
        
        if docker-compose exec -T db pg_isready -U postgres >/dev/null 2>&1; then
            echo "Database Tables:"
            docker-compose exec -T db psql -U postgres -d lnbits -c "\dt"
            
            echo "\nAccounts Table:"
            docker-compose exec -T db psql -U postgres -d lnbits -c "SELECT * FROM accounts;"
            
            echo "\nSettings Table:"
            docker-compose exec -T db psql -U postgres -d lnbits -c "SELECT * FROM settings;"
            
            echo "\nWallets Table:"
            docker-compose exec -T db psql -U postgres -d lnbits -c "SELECT * FROM wallets;"
            
            superuser=$(docker-compose exec -T db psql -U postgres -d lnbits -t -c "SELECT id FROM accounts LIMIT 1;")
            if [ ! -z "$superuser" ]; then
                echo "Found superuser ID: $superuser"
                return 0
            fi
            echo "Database ready but settings not initialized yet..."
        else
            echo "Database not ready yet..."
        fi
        
        attempt=$((attempt + 1))
        sleep 10
    done
    
    echo "Failed to get superuser ID after $max_attempts attempts. Showing LNbits logs:"
    docker-compose logs lnbits --tail 50
    return 1
}

# Stop any running containers and remove postgres volume
docker-compose down
docker volume rm lnbits_postgres_data || true

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

# Start containers
BRANCH=$BRANCH docker-compose up -d

# Wait for LNbits to initialize and get superuser ID
get_superuser

echo "Build and push completed. Container starting now..."
echo "Using branch: $BRANCH"
