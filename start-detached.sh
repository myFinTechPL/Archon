#!/bin/bash
# Archon Full Local Setup - Start Detached
# Runs Supabase + Archon all in Docker, no local processes needed

set -e

COMPOSE_FILE="docker-compose.full.yml"
MIGRATION_FILE="migration/complete_setup.sql"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Archon Full Local Setup (Detached)     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
echo

# Check Docker is running
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}✗ Docker is not running. Please start Docker Desktop.${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Docker is running"

# Check compose file exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${RED}✗ $COMPOSE_FILE not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Compose file found"

# Check .env exists
if [ ! -f ".env" ]; then
    echo -e "${YELLOW}! .env not found, copying from .env.example${NC}"
    cp .env.example .env
fi
echo -e "${GREEN}✓${NC} Environment file ready"

# Check required Supabase init files
REQUIRED_FILES=(
    "volumes/db/roles.sql"
    "volumes/db/jwt.sql"
    "volumes/db/webhooks.sql"
    "volumes/db/realtime.sql"
    "volumes/db/_supabase.sql"
    "volumes/db/logs.sql"
    "volumes/db/pooler.sql"
    "volumes/api/kong.yml"
)

MISSING_FILES=()
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        MISSING_FILES+=("$file")
    fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    echo -e "${YELLOW}! Downloading missing Supabase config files...${NC}"
    
    mkdir -p volumes/db volumes/api
    
    BASE_URL="https://raw.githubusercontent.com/supabase/supabase/master/docker"
    
    for file in "${MISSING_FILES[@]}"; do
        echo "  Downloading $file..."
        curl -sL "$BASE_URL/$file" -o "$file"
    done
    echo -e "${GREEN}✓${NC} Supabase config files downloaded"
else
    echo -e "${GREEN}✓${NC} Supabase config files present"
fi

# Stop any existing containers
echo
echo -e "${BLUE}Stopping any existing containers...${NC}"
docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true

# Build and start
echo
echo -e "${BLUE}Building and starting services (this may take a few minutes on first run)...${NC}"
docker compose -f "$COMPOSE_FILE" up -d --build

# Wait for services to be healthy
echo
echo -e "${BLUE}Waiting for services to be ready...${NC}"

wait_for_service() {
    local service=$1
    local url=$2
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s "$url" > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} $service is ready"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    echo -e "${YELLOW}! $service may still be starting${NC}"
    return 1
}

wait_for_service "Supabase Studio" "http://localhost:${SUPABASE_STUDIO_PORT:-18323}" || true
wait_for_service "Archon Server" "http://localhost:${ARCHON_SERVER_PORT:-18181}/health" || true
wait_for_service "Archon UI" "http://localhost:${ARCHON_UI_PORT:-13737}" || true

# Check if migration needed
echo
echo -e "${BLUE}Checking database setup...${NC}"

# Load port config from .env
source .env 2>/dev/null || true
SUPABASE_API_PORT=${SUPABASE_API_PORT:-18000}
SUPABASE_STUDIO_PORT=${SUPABASE_STUDIO_PORT:-18323}
SUPABASE_DB_PORT=${SUPABASE_DB_PORT:-15432}
ARCHON_UI_PORT=${ARCHON_UI_PORT:-13737}
ARCHON_SERVER_PORT=${ARCHON_SERVER_PORT:-18181}
ARCHON_MCP_PORT=${ARCHON_MCP_PORT:-18051}

# Simple check - try to access the archon_settings table via Supabase API
SERVICE_KEY=$(grep "^SERVICE_ROLE_KEY=" .env | cut -d'=' -f2)
MIGRATION_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $SERVICE_KEY" \
    "http://localhost:${SUPABASE_API_PORT}/rest/v1/archon_settings?limit=1" 2>/dev/null || echo "000")

if [ "$MIGRATION_CHECK" = "200" ]; then
    echo -e "${GREEN}✓${NC} Database already configured"
else
    echo -e "${YELLOW}!${NC} Database migration needed"
    echo
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ACTION REQUIRED: Run database migration                   ║${NC}"
    echo -e "${YELLOW}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  1. Open Supabase Studio: ${BLUE}http://localhost:${SUPABASE_STUDIO_PORT}${YELLOW}           ║${NC}"
    echo -e "${YELLOW}║  2. Go to SQL Editor (left sidebar)                        ║${NC}"
    echo -e "${YELLOW}║  3. Copy contents of: ${BLUE}migration/complete_setup.sql${YELLOW}        ║${NC}"
    echo -e "${YELLOW}║  4. Paste and click 'Run'                                  ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
fi

# Print summary
echo
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Services Running                        ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Archon UI:        ${BLUE}http://localhost:${ARCHON_UI_PORT}${NC}"
echo -e "${GREEN}║${NC}  Archon API:       ${BLUE}http://localhost:${ARCHON_SERVER_PORT}${NC}"
echo -e "${GREEN}║${NC}  Archon MCP:       ${BLUE}http://localhost:${ARCHON_MCP_PORT}${NC}"
echo -e "${GREEN}║${NC}  Supabase API:     ${BLUE}http://localhost:${SUPABASE_API_PORT}${NC}"
echo -e "${GREEN}║${NC}  Supabase Studio:  ${BLUE}http://localhost:${SUPABASE_STUDIO_PORT}${NC}"
echo -e "${GREEN}║${NC}  PostgreSQL:       ${BLUE}localhost:${SUPABASE_DB_PORT}${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Stop:    ${YELLOW}docker compose -f $COMPOSE_FILE down${NC}"
echo -e "${GREEN}║${NC}  Logs:    ${YELLOW}docker compose -f $COMPOSE_FILE logs -f${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
