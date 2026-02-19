#!/bin/bash
# ==============================================================================
# ArangoDB - Import Teaching Datasets
# ==============================================================================
# Downloads and imports the Yelp Academic Dataset and Airbnb listings
# from a GCS bucket into the course ArangoDB database.
#
# Datasets:
#   - yelp_dataset.tar            → yelp_business, yelp_review, yelp_user, etc.
#   - listingsAndReviews.json.tgz → airbnb_listingsAndReviews
#
# All collections are imported into the course database (e.g. cs143).
#
# Prerequisites:
#   - arangodb-bootstrap.sh has been run
#   - gsutil or gcloud CLI is available
#   - arangoimport is installed (comes with arangodb3)
#
# Usage:
#   sudo ./arangodb-import-datasets.sh
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/arangodb-config.json"

GCS_BUCKET="gs://teaching_datasets"
TEMP_DIR="/tmp/arangodb-import-$$"
COURSE_DB=""
ARANGO_ROOT_PASSWORD=""
ARANGO_HOST="127.0.0.1"
ARANGO_PORT=8529

# ==============================================================================
# LOAD CONFIG
# ==============================================================================
if [[ -f "$CONFIG_FILE" ]]; then
    if command -v jq > /dev/null 2>&1; then
        COURSE_DB=$(jq -r '.course_db // ""' "$CONFIG_FILE")
        ARANGO_ROOT_PASSWORD=$(jq -r '.arango_root_password // ""' "$CONFIG_FILE")
        echo "Loaded configuration from $CONFIG_FILE"
    fi
fi

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --course-db)
            COURSE_DB="$2"
            shift 2
            ;;
        --arango-root-password)
            ARANGO_ROOT_PASSWORD="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Downloads and imports Yelp + Airbnb datasets into ArangoDB."
            echo ""
            echo "Options:"
            echo "  --course-db <name>                Target database (default: from config)"
            echo "  --arango-root-password <pass>     ArangoDB root password"
            echo "  --help, -h                        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ==============================================================================
# VALIDATION
# ==============================================================================
if [[ -z "$COURSE_DB" ]]; then
    echo "Error: Course database name not set."
    echo "Set 'course_db' in $CONFIG_FILE or use --course-db"
    exit 1
fi

if [[ -z "$ARANGO_ROOT_PASSWORD" ]]; then
    read -s -p "Enter ArangoDB root password: " ARANGO_ROOT_PASSWORD
    echo ""
fi

# Install gsutil if not present
if ! command -v gsutil > /dev/null 2>&1; then
    echo "gsutil not found. Installing Google Cloud CLI..."
    snap install google-cloud-cli --classic
    echo "Google Cloud CLI installed."
    echo "You may need to run 'gcloud auth login' to authenticate."
fi

if ! command -v arangoimport > /dev/null 2>&1; then
    echo "Error: 'arangoimport' is not installed. Install ArangoDB first."
    exit 1
fi

# Verify ArangoDB is running
if ! curl -sf "http://${ARANGO_HOST}:${ARANGO_PORT}/_api/version" \
    -u "root:${ARANGO_ROOT_PASSWORD}" > /dev/null 2>&1; then
    echo "Error: Cannot connect to ArangoDB."
    exit 1
fi

# Ensure course database exists
exists=$(curl -sf "http://${ARANGO_HOST}:${ARANGO_PORT}/_api/database" \
    -u "root:${ARANGO_ROOT_PASSWORD}" | jq -r ".result[]" 2>/dev/null \
    | grep -c "^${COURSE_DB}$" || true)
if [[ "$exists" -eq 0 ]]; then
    echo "Creating database: $COURSE_DB"
    curl -sf -X POST "http://${ARANGO_HOST}:${ARANGO_PORT}/_api/database" \
        -u "root:${ARANGO_ROOT_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$COURSE_DB\"}" > /dev/null
fi

# Common arangoimport args
ARANGO_ARGS="--server.endpoint tcp://${ARANGO_HOST}:${ARANGO_PORT} \
    --server.username root \
    --server.password ${ARANGO_ROOT_PASSWORD} \
    --server.database ${COURSE_DB}"

echo "=============================================="
echo "ArangoDB - Import Teaching Datasets"
echo "=============================================="
echo "Target database: $COURSE_DB"
echo ""

# ==============================================================================
# SETUP
# ==============================================================================
DATA_DIR="/opt/teaching-datasets"
mkdir -p "$DATA_DIR" "$TEMP_DIR"
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Download helper: check local cache first, then GCS
download_dataset() {
    local filename="$1"
    if [[ -f "$DATA_DIR/$filename" ]]; then
        echo "Found local copy: $DATA_DIR/$filename"
        cp "$DATA_DIR/$filename" "$TEMP_DIR/"
    else
        echo "Downloading $filename from GCS..."
        gsutil cp "${GCS_BUCKET}/$filename" "$DATA_DIR/"
        cp "$DATA_DIR/$filename" "$TEMP_DIR/"
    fi
}

# ==============================================================================
# IMPORT HELPER
# ==============================================================================
import_json_file() {
    local file="$1"
    local collection="$2"
    local file_size

    file_size=$(du -h "$file" | cut -f1)
    echo "  Importing $file ($file_size) → $COURSE_DB.$collection"

    # arangoimport: --type jsonl for line-delimited JSON (Yelp format)
    # --on-duplicate update to handle re-runs
    # --overwrite to clear existing collection data
    arangoimport \
        $ARANGO_ARGS \
        --collection "$collection" \
        --create-collection true \
        --file "$file" \
        --type jsonl \
        --overwrite true \
        2>&1 | grep -E "created:|errors:|updated:" || true

    echo "  ✓ $collection imported."
}

# ==============================================================================
# 1. DOWNLOAD AND IMPORT AIRBNB DATA
# ==============================================================================
echo "----------------------------------------------"
echo "1. Airbnb - listingsAndReviews"
echo "----------------------------------------------"

download_dataset "listingsAndReviews.json.tgz"

echo "Extracting..."
cd "$TEMP_DIR"
tar xzf listingsAndReviews.json.tgz

airbnb_count=0
for json_file in $(find "$TEMP_DIR" -name "*.json" -not -path "*/yelp*" | sort); do
    basename_noext=$(basename "$json_file" .json)
    collection="airbnb_${basename_noext}"
    import_json_file "$json_file" "$collection"
    airbnb_count=$((airbnb_count + 1))
done

rm -f "$TEMP_DIR/listingsAndReviews.json.tgz"
find "$TEMP_DIR" -name "*.json" -not -name "yelp_*" -delete 2>/dev/null || true
echo ""

# ==============================================================================
# 2. DOWNLOAD AND IMPORT YELP DATA
# ==============================================================================
echo "----------------------------------------------"
echo "2. Yelp Academic Dataset"
echo "----------------------------------------------"

download_dataset "yelp_dataset.tar"

echo "Extracting..."
cd "$TEMP_DIR"
tar xf yelp_dataset.tar

yelp_count=0
for json_file in $(find "$TEMP_DIR" -name "yelp_academic_dataset_*.json" | sort); do
    basename_noext=$(basename "$json_file" .json)
    type_name=${basename_noext#yelp_academic_dataset_}
    collection="yelp_${type_name}"
    import_json_file "$json_file" "$collection"
    yelp_count=$((yelp_count + 1))
done

echo ""

# ==============================================================================
# SUMMARY
# ==============================================================================
echo "=============================================="
echo "Import Complete!"
echo "=============================================="
echo ""
echo "Database: $COURSE_DB"
echo "  - Airbnb collections imported: $airbnb_count"
echo "  - Yelp collections imported:   $yelp_count"
echo ""
echo "Collections created:"
curl -sf "http://${ARANGO_HOST}:${ARANGO_PORT}/_db/${COURSE_DB}/_api/collection" \
    -u "root:${ARANGO_ROOT_PASSWORD}" \
    | jq -r '.result[] | select(.isSystem == false) | "  - " + .name' 2>/dev/null || true
echo ""
echo "Students can access via: arangosh"
echo "  db._query('FOR doc IN yelp_business LIMIT 1 RETURN doc').toArray()"
echo "  db._query('FOR doc IN airbnb_listingsAndReviews LIMIT 1 RETURN doc').toArray()"
echo "=============================================="
