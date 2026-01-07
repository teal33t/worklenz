#!/bin/bash

# Script to create a new user in Worklenz
# Usage: ./create-user.sh [name] [email] [password]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Database connection details
DB_CONTAINER="worklenz_db"
DB_USER="postgres"
DB_NAME="worklenz_db"

# Function to print colored messages
print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_info() {
    echo -e "${YELLOW}$1${NC}"
}

# Check if Docker container is running
if ! docker ps | grep -q "$DB_CONTAINER"; then
    print_error "Database container '$DB_CONTAINER' is not running."
    echo "Please start the application first with: ./start.sh"
    exit 1
fi

# Get user input
if [ -z "$1" ]; then
    read -p "Enter user's full name: " USER_NAME
else
    USER_NAME="$1"
fi

if [ -z "$2" ]; then
    read -p "Enter email address: " USER_EMAIL
else
    USER_EMAIL="$2"
fi

if [ -z "$3" ]; then
    read -sp "Enter password: " USER_PASSWORD
    echo
    read -sp "Confirm password: " USER_PASSWORD_CONFIRM
    echo
    
    if [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; then
        print_error "Passwords do not match!"
        exit 1
    fi
else
    USER_PASSWORD="$3"
fi

# Validate inputs
if [ -z "$USER_NAME" ] || [ -z "$USER_EMAIL" ] || [ -z "$USER_PASSWORD" ]; then
    print_error "All fields are required!"
    exit 1
fi

# Check if email already exists
EMAIL_EXISTS=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM users WHERE email = '$USER_EMAIL';" 2>/dev/null | xargs)

if [ "$EMAIL_EXISTS" -gt 0 ]; then
    print_error "A user with email '$USER_EMAIL' already exists!"
    exit 1
fi

print_info "Creating user..."

# Create the user
SQL_COMMAND="
DO \$\$
DECLARE
    v_user_id UUID;
    v_team_id UUID;
    v_role_id UUID;
BEGIN
    -- Insert user
    INSERT INTO users (name, email, password, timezone_id, setup_completed)
    VALUES (
        '$USER_NAME',
        '$USER_EMAIL',
        crypt('$USER_PASSWORD', gen_salt('bf')),
        (SELECT id FROM timezones WHERE name = 'UTC'),
        true
    )
    RETURNING id INTO v_user_id;

    -- Create organization/team
    INSERT INTO teams (name, user_id)
    VALUES ('$USER_NAME''s Team', v_user_id)
    RETURNING id INTO v_team_id;

    -- Update user's active team
    UPDATE users SET active_team = v_team_id WHERE id = v_user_id;

    -- Get admin role
    SELECT id INTO v_role_id FROM roles WHERE name = 'Admin' LIMIT 1;

    -- Add user as team member
    INSERT INTO team_members (team_id, user_id, role_id, active)
    VALUES (v_team_id, v_user_id, v_role_id, true);

    -- Create user data entry
    INSERT INTO users_data (user_id, organization_name, trial_in_progress, trial_expire_date, subscription_status)
    VALUES (v_user_id, '$USER_NAME''s Team', TRUE, CURRENT_DATE + INTERVAL '14 days', 'trialing');

    -- Create organization entry
    INSERT INTO organizations (user_id, organization_name, user_count)
    VALUES (v_user_id, '$USER_NAME''s Team', 1);

    RAISE NOTICE 'User created successfully with ID: %', v_user_id;
END \$\$;
"

# Execute the SQL command
if docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "$SQL_COMMAND" 2>&1 | grep -q "User created successfully"; then
    print_success "✓ User created successfully!"
    echo ""
    print_info "Login credentials:"
    echo "  Email: $USER_EMAIL"
    echo "  Password: [hidden]"
    echo ""
    print_info "The user has been given a 14-day trial period."
else
    print_error "Failed to create user. Please check the error messages above."
    exit 1
fi
