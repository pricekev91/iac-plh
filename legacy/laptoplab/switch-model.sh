#!/bin/bash

# Configuration
MODELS_DIR="/srv/ai/models"
SERVICE_FILE="/etc/systemd/system/llama-server.service"
SERVICE_NAME="llama-server.service"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Llama Server Model Switcher ===${NC}\n"

# Check if models directory exists
if [ ! -d "$MODELS_DIR" ]; then
    echo -e "${RED}Error: Models directory not found: $MODELS_DIR${NC}"
    exit 1
fi

# Find all .gguf files and sort by modification time (newest first)
mapfile -t models < <(find "$MODELS_DIR" -maxdepth 1 -type f -name "*.gguf" -printf "%T@ %p\n" | sort -rn | cut -d' ' -f2-)

# Check if any models were found
if [ ${#models[@]} -eq 0 ]; then
    echo -e "${RED}Error: No .gguf model files found in $MODELS_DIR${NC}"
    exit 1
fi

# Display models with numbers
echo -e "${GREEN}Available models (newest to oldest):${NC}\n"
for i in "${!models[@]}"; do
    model_name=$(basename "${models[$i]}")
    mod_time=$(stat -c "%y" "${models[$i]}" | cut -d'.' -f1)
    echo -e "${YELLOW}$((i+1)).${NC} $model_name"
    echo -e "   Modified: $mod_time"
    echo
done

# Get user selection
while true; do
    read -p "Select model number (1-${#models[@]}): " selection

    # Validate input
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#models[@]} ]; then
        break
    else
        echo -e "${RED}Invalid selection. Please enter a number between 1 and ${#models[@]}${NC}"
    fi
done

# Get selected model path
selected_model="${models[$((selection-1))]}"
echo -e "\n${GREEN}Selected model:${NC} $(basename "$selected_model")"

# Backup service file
if [ -f "$SERVICE_FILE" ]; then
    cp "$SERVICE_FILE" "${SERVICE_FILE}.bak"
    echo -e "${GREEN}Backup created:${NC} ${SERVICE_FILE}.bak"
else
    echo -e "${RED}Warning: Service file not found: $SERVICE_FILE${NC}"
    exit 1
fi

# Update service file with new model path
sed -i "s|--model .*/.*\.gguf|--model $selected_model|g" "$SERVICE_FILE"
echo -e "${GREEN}Service file updated${NC}"

# Reload systemd daemon
echo -e "\n${BLUE}Reloading systemd daemon...${NC}"
systemctl daemon-reload

# Restart service
echo -e "${BLUE}Restarting $SERVICE_NAME...${NC}"
systemctl restart "$SERVICE_NAME"

# Check service status
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "\n${GREEN}✓ Service restarted successfully!${NC}"
    echo -e "${GREEN}✓ Now using model:${NC} $(basename "$selected_model")"
else
    echo -e "\n${RED}✗ Service failed to start. Check status with: systemctl status $SERVICE_NAME${NC}"
    exit 1
fi

echo -e "\n${BLUE}Done!${NC}"
