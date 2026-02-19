#!/bin/bash
# ==============================================================================
# MongoDB - Import Teaching Datasets
# ==============================================================================
# Downloads and imports the Yelp Academic Dataset and Airbnb listings
# from a GCS bucket into the course MongoDB database.
#
# Datasets:
#   - yelp_dataset.tar          → yelp_business, yelp_review, yelp_user, etc.
#   - listingsAndReviews.json.tgz → airbnb_listingsAndReviews
#
# All collections are imported into the course database (e.g. cs143).
#
# Prerequisites:
#   - mongodb-bootstrap.sh has been run
#   - gsutil or gcloud CLI is available
#   - mongoimport is installed (comes with mongodb-database-tools)
#
# Usage:
#   sudo ./mongodb-import-datasets.sh
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/mongodb-config.json"

GCS_BUCKET="gs://teaching_datasets"
TEMP_DIR="/tmp/mongodb-import-$$"
COURSE_DB=""
MONGO_ADMIN_USER=""
MONGO_ADMIN_PASS=""

# MongoDB TLS settings
CERT_DIR="/etc/mongodb/ssl"
CA_CERT="$CERT_DIR/ca.pem"

# ==============================================================================
# LOAD CONFIG
# ==============================================================================
if [[ -f "$CONFIG_FILE" ]]; then
    if command -v jq > /dev/null 2>&1; then
        COURSE_DB=$(jq -r '.course_db // ""' "$CONFIG_FILE")
        MONGO_ADMIN_USER=$(jq -r '.mongo_admin_user // "mongoadmin"' "$CONFIG_FILE")
        MONGO_ADMIN_PASS=$(jq -r '.mongo_admin_pass // ""' "$CONFIG_FILE")
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
        --admin-user)
            MONGO_ADMIN_USER="$2"
            shift 2
            ;;
        --admin-pass)
            MONGO_ADMIN_PASS="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Downloads and imports Yelp + Airbnb datasets into MongoDB."
            echo ""
            echo "Options:"
            echo "  --course-db <name>       Target database (default: from config)"
            echo "  --admin-user <user>      MongoDB admin username"
            echo "  --admin-pass <pass>      MongoDB admin password"
            echo "  --help, -h               Show this help message"
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

if [[ -z "$MONGO_ADMIN_PASS" ]]; then
    read -s -p "Enter MongoDB admin password for '$MONGO_ADMIN_USER': " MONGO_ADMIN_PASS
    echo ""
fi

# Install gsutil if not present
if ! command -v gsutil > /dev/null 2>&1; then
    echo "gsutil not found. Installing Google Cloud CLI..."
    snap install google-cloud-cli --classic
    echo "Google Cloud CLI installed."
    echo "You may need to run 'gcloud auth login' to authenticate."
fi

# Check for mongoimport
if ! command -v mongoimport > /dev/null 2>&1; then
    echo "Error: 'mongoimport' is not installed."
    echo "Install with: sudo apt install mongodb-database-tools"
    exit 1
fi

# Build mongoimport auth args
MONGO_AUTH_ARGS=""
if [[ -f "$CA_CERT" ]]; then
    MONGO_AUTH_ARGS="--ssl --sslCAFile=$CA_CERT"
fi
MONGO_AUTH_ARGS="$MONGO_AUTH_ARGS --username=$MONGO_ADMIN_USER --password=$MONGO_ADMIN_PASS --authenticationDatabase=admin"

echo "=============================================="
echo "MongoDB - Import Teaching Datasets"
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

    mongoimport \
        $MONGO_AUTH_ARGS \
        --db "$COURSE_DB" \
        --collection "$collection" \
        --file "$file" \
        --drop \
        2>&1 | tail -1

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

# Find and import all JSON files with airbnb_ prefix
airbnb_count=0
for json_file in $(find "$TEMP_DIR" -name "*.json" -not -path "*/yelp*" | sort); do
    basename_noext=$(basename "$json_file" .json)
    collection="airbnb_${basename_noext}"

    import_json_file "$json_file" "$collection"
    airbnb_count=$((airbnb_count + 1))
done

# Clean up extracted files before yelp extraction
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

# Find and import all Yelp JSON files with yelp_ prefix
# Yelp files are named: yelp_academic_dataset_<type>.json
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

# List collections
if [[ -f "$CA_CERT" ]]; then
    mongosh "mongodb://127.0.0.1:27017/${COURSE_DB}" \
        --tls --tlsCAFile "$CA_CERT" \
        --username "$MONGO_ADMIN_USER" --password "$MONGO_ADMIN_PASS" \
        --authenticationDatabase admin \
        --quiet --eval "db.getCollectionNames().forEach(c => print('  - ' + c))" 2>/dev/null || true
else
    mongosh "mongodb://127.0.0.1:27017/${COURSE_DB}" \
        --username "$MONGO_ADMIN_USER" --password "$MONGO_ADMIN_PASS" \
        --authenticationDatabase admin \
        --quiet --eval "db.getCollectionNames().forEach(c => print('  - ' + c))" 2>/dev/null || true
fi

echo ""
echo "Students can access via: mongosh"
echo "  db.yelp_business.findOne()"
echo "  db.airbnb_listingsAndReviews.findOne()"
echo "=============================================="
