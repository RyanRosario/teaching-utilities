#!/bin/bash
# ==============================================================================
# ChromaDB - Import Teaching Datasets
# ==============================================================================
# Downloads the Yelp Academic Dataset and Airbnb listings from a GCS bucket
# and imports text fields as vector embeddings into the course ChromaDB tenant.
#
# ChromaDB is a vector database — it stores embeddings, not raw JSON documents.
# This script extracts text fields from each dataset and creates searchable
# vector collections:
#
#   Yelp:
#     - yelp_reviews:    review text + metadata (stars, business_id, user_id)
#     - yelp_businesses: name + categories + city + metadata (stars, review_count)
#     - yelp_tips:       tip text + metadata (business_id, user_id)
#
#   Airbnb:
#     - airbnb_listings: name + summary + description + metadata (price, beds, etc.)
#
# ChromaDB uses its built-in default embedding function (all-MiniLM-L6-v2).
#
# Prerequisites:
#   - chromadb-bootstrap.sh has been run
#   - gsutil or gcloud CLI is available
#   - sentence-transformers is installed (for default embeddings)
#
# Usage:
#   sudo ./chromadb-import-datasets.sh
# ==============================================================================

set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/chromadb-config.json"

GCS_BUCKET="gs://teaching-datasets"
TEMP_DIR="/tmp/chromadb-import-$$"
COURSE_DB=""
CHROMA_HOST="127.0.0.1"
CHROMA_PORT=8000
CHROMA_SERVER_TOKEN=""

# Max documents to import per collection (vector DBs are slower to ingest)
MAX_YELP_REVIEWS=50000
MAX_YELP_BUSINESSES=0        # 0 = all
MAX_YELP_TIPS=50000
MAX_AIRBNB_LISTINGS=0        # 0 = all
BATCH_SIZE=500

# ==============================================================================
# LOAD CONFIG
# ==============================================================================
if [[ -f "$CONFIG_FILE" ]]; then
    if command -v jq > /dev/null 2>&1; then
        COURSE_DB=$(jq -r '.course_db // ""' "$CONFIG_FILE")
        CHROMA_PORT=$(jq -r '.chroma_port // 8000' "$CONFIG_FILE")
        echo "Loaded configuration from $CONFIG_FILE"
    fi
fi

# Read server token
if [[ -f /etc/chromadb-server-token ]]; then
    CHROMA_SERVER_TOKEN=$(cat /etc/chromadb-server-token)
fi

# Read server config
if [[ -f /etc/chromadb/server.json ]]; then
    CHROMA_PORT=$(jq -r '.port // 8000' /etc/chromadb/server.json)
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
        --max-reviews)
            MAX_YELP_REVIEWS="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Downloads Yelp + Airbnb datasets and imports text as vector"
            echo "embeddings into ChromaDB for semantic search."
            echo ""
            echo "Options:"
            echo "  --course-db <name>       Target tenant (default: from config)"
            echo "  --max-reviews <n>        Max Yelp reviews to import (default: $MAX_YELP_REVIEWS)"
            echo "  --help, -h               Show this help message"
            echo ""
            echo "Note: Vector embedding is slow. Default limits apply."
            echo "Airbnb listings and Yelp businesses are imported in full."
            echo "Yelp reviews/tips are limited to ${MAX_YELP_REVIEWS} by default."
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
    exit 1
fi

if [[ -z "$CHROMA_SERVER_TOKEN" ]]; then
    echo "Error: Server token not found. Run chromadb-bootstrap.sh first."
    exit 1
fi

# Install gsutil if not present
if ! command -v gsutil > /dev/null 2>&1; then
    echo "gsutil not found. Installing Google Cloud CLI..."
    snap install google-cloud-cli --classic
    echo "Google Cloud CLI installed."
    echo "You may need to run 'gcloud auth login' or configure a service account."
fi

echo "=============================================="
echo "ChromaDB - Import Teaching Datasets"
echo "=============================================="
echo "Target tenant: $COURSE_DB"
echo ""

# ==============================================================================
# SETUP
# ==============================================================================
mkdir -p "$TEMP_DIR"
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Install sentence-transformers if needed
echo "Ensuring embedding dependencies are installed..."
/opt/chromadb/venv/bin/pip install -q sentence-transformers 2>/dev/null || true

# ==============================================================================
# DOWNLOAD DATASETS
# ==============================================================================
echo "----------------------------------------------"
echo "Downloading datasets from GCS..."
echo "----------------------------------------------"

echo "Downloading listingsAndReviews.json.tgz..."
gsutil cp "${GCS_BUCKET}/listingsAndReviews.json.tgz" "$TEMP_DIR/"

echo "Downloading yelp_dataset.tar..."
gsutil cp "${GCS_BUCKET}/yelp_dataset.tar" "$TEMP_DIR/"

echo "Extracting..."
cd "$TEMP_DIR"
tar xzf listingsAndReviews.json.tgz
tar xf yelp_dataset.tar
echo "Extraction complete."
echo ""

# ==============================================================================
# PYTHON IMPORT SCRIPT
# ==============================================================================
echo "----------------------------------------------"
echo "Importing into ChromaDB (this may take a while)..."
echo "----------------------------------------------"

export CHROMA_HOST="$CHROMA_HOST"
export CHROMA_PORT="$CHROMA_PORT"
export CHROMA_TOKEN="$CHROMA_SERVER_TOKEN"
export COURSE_DB="$COURSE_DB"
export TEMP_DIR="$TEMP_DIR"
export MAX_YELP_REVIEWS="$MAX_YELP_REVIEWS"
export MAX_YELP_TIPS="$MAX_YELP_TIPS"
export BATCH_SIZE="$BATCH_SIZE"

/opt/chromadb/venv/bin/python3 - <<'PYEOF'
import json
import os
import sys
import glob

import chromadb
from chromadb.config import Settings

# Configuration from environment variables (set by shell wrapper)
CHROMA_HOST = os.environ.get("CHROMA_HOST", "127.0.0.1")
CHROMA_PORT = int(os.environ.get("CHROMA_PORT", "8000"))
CHROMA_TOKEN = os.environ["CHROMA_TOKEN"]
COURSE_DB = os.environ["COURSE_DB"]
TEMP_DIR = os.environ.get("TEMP_DIR", "/tmp")

MAX_YELP_REVIEWS = int(os.environ.get("MAX_YELP_REVIEWS", "50000"))
MAX_YELP_TIPS = int(os.environ.get("MAX_YELP_TIPS", "50000"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "500"))

print(f"Connecting to ChromaDB at {CHROMA_HOST}:{CHROMA_PORT}...")

# Create admin client to ensure tenant/database exist
try:
    admin = chromadb.AdminClient(Settings(
        chroma_server_host=CHROMA_HOST,
        chroma_server_http_port=CHROMA_PORT,
        chroma_client_auth_provider="chromadb.auth.token_authn.TokenAuthClientProvider",
        chroma_client_auth_credentials=CHROMA_TOKEN,
        chroma_auth_token_transport_header="Authorization",
    ))
    try:
        admin.create_tenant(COURSE_DB)
    except Exception:
        pass
    try:
        admin.create_database("default", tenant=COURSE_DB)
    except Exception:
        pass
except Exception as e:
    print(f"Warning: Could not create tenant/database: {e}")

# Connect to course tenant
client = chromadb.HttpClient(
    host=CHROMA_HOST,
    port=CHROMA_PORT,
    tenant=COURSE_DB,
    database="default",
    settings=Settings(
        chroma_client_auth_provider="chromadb.auth.token_authn.TokenAuthClientProvider",
        chroma_client_auth_credentials=CHROMA_TOKEN,
        chroma_auth_token_transport_header="Authorization",
    ),
)

def batch_add(collection, ids, documents, metadatas):
    """Add documents in batches."""
    total = len(ids)
    for i in range(0, total, BATCH_SIZE):
        end = min(i + BATCH_SIZE, total)
        collection.add(
            ids=ids[i:end],
            documents=documents[i:end],
            metadatas=metadatas[i:end],
        )
        if (i + BATCH_SIZE) % 5000 == 0 or end == total:
            print(f"    Progress: {end}/{total}")

def read_jsonl(filepath, max_lines=0):
    """Read a JSONL file, yielding parsed objects."""
    count = 0
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
                count += 1
                if max_lines > 0 and count >= max_lines:
                    return
            except json.JSONDecodeError:
                continue

# =========================================================================
# 1. YELP BUSINESSES
# =========================================================================
yelp_biz_file = glob.glob(os.path.join(TEMP_DIR, "**/yelp_academic_dataset_business.json"), recursive=True)
if yelp_biz_file:
    print("\n--- Importing yelp_businesses ---")
    collection = client.get_or_create_collection("yelp_businesses")

    ids, docs, metas = [], [], []
    for obj in read_jsonl(yelp_biz_file[0]):
        biz_id = obj.get("business_id", "")
        name = obj.get("name", "")
        categories = obj.get("categories", "") or ""
        city = obj.get("city", "")
        state = obj.get("state", "")

        doc_text = f"{name}. {categories}. {city}, {state}"
        if not doc_text.strip(". "):
            continue

        ids.append(biz_id)
        docs.append(doc_text)
        metas.append({
            "name": name,
            "city": city,
            "state": state,
            "stars": float(obj.get("stars", 0)),
            "review_count": int(obj.get("review_count", 0)),
            "categories": categories[:500],  # ChromaDB metadata size limit
        })

    print(f"  Embedding {len(ids)} businesses...")
    batch_add(collection, ids, docs, metas)
    print(f"  ✓ yelp_businesses: {len(ids)} documents")

# =========================================================================
# 2. YELP REVIEWS (limited)
# =========================================================================
yelp_rev_file = glob.glob(os.path.join(TEMP_DIR, "**/yelp_academic_dataset_review.json"), recursive=True)
if yelp_rev_file:
    print(f"\n--- Importing yelp_reviews (limit: {MAX_YELP_REVIEWS}) ---")
    collection = client.get_or_create_collection("yelp_reviews")

    ids, docs, metas = [], [], []
    for obj in read_jsonl(yelp_rev_file[0], max_lines=MAX_YELP_REVIEWS):
        review_id = obj.get("review_id", "")
        text = obj.get("text", "")
        if not text:
            continue

        ids.append(review_id)
        docs.append(text[:8000])  # Truncate very long reviews
        metas.append({
            "business_id": obj.get("business_id", ""),
            "user_id": obj.get("user_id", ""),
            "stars": float(obj.get("stars", 0)),
            "useful": int(obj.get("useful", 0)),
            "funny": int(obj.get("funny", 0)),
            "cool": int(obj.get("cool", 0)),
            "date": obj.get("date", ""),
        })

    print(f"  Embedding {len(ids)} reviews...")
    batch_add(collection, ids, docs, metas)
    print(f"  ✓ yelp_reviews: {len(ids)} documents")

# =========================================================================
# 3. YELP TIPS (limited)
# =========================================================================
yelp_tip_file = glob.glob(os.path.join(TEMP_DIR, "**/yelp_academic_dataset_tip.json"), recursive=True)
if yelp_tip_file:
    print(f"\n--- Importing yelp_tips (limit: {MAX_YELP_TIPS}) ---")
    collection = client.get_or_create_collection("yelp_tips")

    ids, docs, metas = [], [], []
    idx = 0
    for obj in read_jsonl(yelp_tip_file[0], max_lines=MAX_YELP_TIPS):
        text = obj.get("text", "")
        if not text:
            continue

        ids.append(f"tip_{idx}")
        docs.append(text)
        metas.append({
            "business_id": obj.get("business_id", ""),
            "user_id": obj.get("user_id", ""),
            "compliment_count": int(obj.get("compliment_count", 0)),
            "date": obj.get("date", ""),
        })
        idx += 1

    print(f"  Embedding {len(ids)} tips...")
    batch_add(collection, ids, docs, metas)
    print(f"  ✓ yelp_tips: {len(ids)} documents")

# =========================================================================
# 4. AIRBNB LISTINGS
# =========================================================================
airbnb_files = glob.glob(os.path.join(TEMP_DIR, "**/listingsAndReviews.json"), recursive=True)
if not airbnb_files:
    airbnb_files = glob.glob(os.path.join(TEMP_DIR, "**/*.json"), recursive=True)
    airbnb_files = [f for f in airbnb_files if "yelp" not in f.lower()]

if airbnb_files:
    print("\n--- Importing airbnb_listings ---")
    collection = client.get_or_create_collection("airbnb_listings")

    ids, docs, metas = [], [], []
    for airbnb_file in airbnb_files:
        for obj in read_jsonl(airbnb_file):
            listing_id = str(obj.get("_id", obj.get("id", obj.get("listing_id", ""))))
            if not listing_id:
                continue

            name = obj.get("name", "")
            summary = obj.get("summary", "") or ""
            description = obj.get("description", "") or ""
            space = obj.get("space", "") or ""
            neighborhood = obj.get("neighborhood_overview", "") or ""

            doc_text = f"{name}. {summary} {description} {space} {neighborhood}".strip()
            if not doc_text.strip(". "):
                continue

            meta = {"name": name}

            # Safely extract metadata
            price_val = obj.get("price", 0)
            if isinstance(price_val, dict) and "$numberDecimal" in price_val:
                price_val = float(price_val["$numberDecimal"])
            elif isinstance(price_val, str):
                price_val = float(price_val.replace("$", "").replace(",", "") or 0)
            meta["price"] = float(price_val) if price_val else 0.0

            if obj.get("bedrooms") is not None:
                meta["bedrooms"] = int(obj.get("bedrooms", 0) or 0)
            if obj.get("beds") is not None:
                meta["beds"] = int(obj.get("beds", 0) or 0)
            if obj.get("property_type"):
                meta["property_type"] = str(obj["property_type"])[:200]
            if obj.get("room_type"):
                meta["room_type"] = str(obj["room_type"])[:200]

            address = obj.get("address", {})
            if isinstance(address, dict):
                if address.get("market"):
                    meta["market"] = str(address["market"])[:200]
                if address.get("country"):
                    meta["country"] = str(address["country"])[:200]

            ids.append(listing_id)
            docs.append(doc_text[:8000])
            metas.append(meta)

    print(f"  Embedding {len(ids)} listings...")
    batch_add(collection, ids, docs, metas)
    print(f"  ✓ airbnb_listings: {len(ids)} documents")

# =========================================================================
# SUMMARY
# =========================================================================
print("\n" + "=" * 46)
print("ChromaDB Import Complete!")
print("=" * 46)
collections = client.list_collections()
for c in collections:
    count = c.count()
    print(f"  - {c.name}: {count} documents")
print()
print("Example queries (Python):")
print('  from chromadb_connect import get_course_client')
print('  client = get_course_client()')
print('  results = client.get_collection("yelp_reviews").query(')
print('      query_texts=["best pizza in town"],')
print('      n_results=5')
print('  )')
PYEOF

echo ""
echo "=============================================="
echo "ChromaDB Dataset Import Complete!"
echo "=============================================="
