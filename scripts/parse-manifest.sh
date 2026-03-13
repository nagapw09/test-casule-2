#!/bin/sh
# MANIFEST parser utility script

get_images() {
    if [ ! -f "MANIFEST" ]; then
        echo ""
        return
    fi
    
    # Extract IMAGE lines from MANIFEST
    # Format: IMAGE <tag> <runnables> <source> <dockerfile>
    # Example: IMAGE myapp/frontend frontend ./frontend Dockerfile
    grep "^IMAGE " MANIFEST | while read line; do
        # Extract tag (first field after IMAGE)
        echo "$line" | awk '{print $2}'
    done
}

get_image_details() {
    if [ ! -f "MANIFEST" ]; then
        echo ""
        return
    fi
    
    local image_tag="$1"
    if [ -z "$image_tag" ]; then
        echo "Error: image_tag required" >&2
        return 1
    fi
    
    # Find the IMAGE line for this tag and extract details
    grep "^IMAGE $image_tag " MANIFEST | head -1 | while read line; do
        # Format: IMAGE <tag> <runnables> <source> <dockerfile>
        tag=$(echo "$line" | awk '{print $2}')
        runnables=$(echo "$line" | awk '{print $3}')
        source=$(echo "$line" | awk '{print $4}')
        dockerfile=$(echo "$line" | awk '{print $5}')
        
        echo "tag=$tag"
        echo "source=$source"
        echo "dockerfile=$dockerfile"
        echo "runnables=$runnables"
    done
}

get_entrypoint() {
    if [ ! -f "MANIFEST" ]; then
        echo ""
        return
    fi
    
    # Extract entrypoint from MANIFEST
    grep "^ENTRY " MANIFEST | awk '{print $2}' | head -1 || echo ""
}

get_secrets() {
    if [ ! -f "MANIFEST" ]; then
        echo ""
        return
    fi
    
    # Extract required secrets from MANIFEST
    grep "^SECRET " MANIFEST | while read line; do
        # Get all secrets from the line (skip the SECRET keyword)
        echo "$line" | awk '{for(i=2;i<=NF;i++) print $i}'
    done
}

# Command dispatcher
case "$1" in
    "get-images")
        get_images
        ;;
    "get-image-details")
        get_image_details "$2"
        ;;
    "get-entrypoint")
        get_entrypoint
        ;;
    "get-secrets")
        get_secrets
        ;;
    *)
        echo "Usage: $0 {get-images|get-image-details <tag>|get-entrypoint|get-secrets}"
        exit 1
        ;;
esac
