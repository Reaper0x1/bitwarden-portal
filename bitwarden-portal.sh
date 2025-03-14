#!/bin/bash

TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")

#-------------------#
# Helper Functions  #
#-------------------#

fix_permissions() {
    local puid="$1"
    local pgid="$2"
    local folder="$3"

    chown -R "$puid:$pgid" "$folder"
}


encrypt_file() {
    local input_file="$1"
    local output_file="$2"
    local password="$3"

    local input_file_name=$(echo "$input_file" | sed 's/\/app\///g')
    local output_file_name=$(echo "$output_file" | sed 's/\/app\///g')

    echo "# Encrypting file: $input_file_name."

    openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$password" -in "$input_file" -out "$output_file"

    if [ $? -ne 0 ]; then
        echo "✕ Error: Failed to encrypt file $input_file."
        exit 1
    fi
    
    echo "# Encryption successful: $output_file_name."
}

decrypt_file() {
    local input_file="$1"
    local output_file="$2"
    local password="$3"

    local input_file_name=$(echo "$input_file" | sed 's/\/app\///g')
    local output_file_name=$(echo "$output_file" | sed 's/\/app\///g')

    echo "# Decrypting file: $input_file_name."

    openssl enc -aes-256-cbc -d -pbkdf2 -pass pass:"$password" -in "$input_file" -out "$output_file"

    if [ $? -ne 0 ]; then
        echo "✕ Error: Failed to decrypt file $input_file."
        exit 1
    fi

    echo "# Decryption successful: $output_file_name."
}

purge_folder() {
    local folder_path="$1"
    local max_files="$2"
    local retention_days="$3"

    local folder_name=$(echo "$folder_path" | sed 's/\/app\///g')

    if [ "$ENABLE_PRUNING" == "false" ]; then
        echo "# Pruning disabled, skipping..."
        return
    elif [ "$ENABLE_PRUNING" != "true" ]; then
        echo "The var ENABLE_PRUNING is invalid (only 'true' or 'false' is accepted): $ENABLE_PRUNING"
        exit 1
    fi

    echo "# Purging files in folder: $folder_name."

    # Find all files in the folder sorted by modification time (oldest first)
    all_files=$(find "$folder_path" -type f -printf "%T@ %p\n" | sort -n)

    # Find files older than the retention period
    old_files=$(find "$folder_path" -type f -mtime +"$retention_days")

    # Find files newer than the retention period
    recent_files=$(find "$folder_path" -type f -mtime -"$retention_days")

    # Check if there are no files in the folder
    if [ -z "$all_files" ]; then
        echo "# No files found in the folder: $folder_path. Nothing to purge."
        return
    fi

    # Case 1: If there are recent files, delete only the files older than retention_days
    if [ -n "$recent_files" ]; then
        if [ -n "$old_files" ]; then
            echo "# Found files modified within the last $retention_days days. Deleting only older files..."
            find "$folder_path" -type f -mtime +"$retention_days" -exec rm -f {} +
        else
            echo "# No files older than $retention_days days to delete. Nothing to purge."
        fi
    else
        # Case 2: If all files are older than retention_days, keep only the most recent max_files files
        echo "# All files are older than $retention_days days. Keeping the most recent $max_files files..."
        echo "$all_files" | head -n -"$max_files" | awk '{print $2}' | xargs -I{} rm -f "{}"
    fi

    echo "# Purge completed for $folder_name."
}


#------#
# INIT #
#------#

# Create folder if not exists 
SOURCE_FOLDER="/app/backups/source"
DEST_FOLDER="/app/backups/dest"

mkdir -p "$SOURCE_FOLDER"

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to create folder /backups/source."
    exit 1
fi

mkdir -p "$DEST_FOLDER"

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to create folder /backups/dest."
    exit 1
fi

echo "########## Start of Backup process ##########"

echo "# Fixing permissions on backups folder..."
fix_permissions "$PUID" "$PGID" "/app/backups"

sleep 1


#--------#
# BACKUP #
#--------#

echo "# Start Time: $(date)"

# Set the filename for our json export as variable
SOURCE_EXPORT_OUTPUT_BASE="bw_export_source_"
SOURCE_NEW_FILENAME="$SOURCE_EXPORT_OUTPUT_BASE$TIMESTAMP.json"
SOURCE_OUTPUT_FILE_PATH="$SOURCE_FOLDER/$SOURCE_NEW_FILENAME"
ENCRYPTED_SOURCE_OUTPUT_FILE_PATH="$SOURCE_OUTPUT_FILE_PATH.enc"


#--------------#
# SOURCE PURGE #
#--------------#

purge_folder "$SOURCE_FOLDER" "$MIN_FILES" "$RETENTION_DAYS"
sleep 1


#--------------#
# SOURCE LOGIN #
#--------------#

# Lets make sure we're logged out before we start
echo "# Logging out from Bitwarden..."
bw logout >/dev/null

export BW_CLIENTID=${SOURCE_CLIENT_ID}
export BW_CLIENTSECRET=${SOURCE_CLIENT_SECRET}

# Login to our Server
echo "# Logging into Source server..."
bw config server "$SOURCE_SERVER"

bw login "$SOURCE_ACCOUNT" --apikey --raw

if [ $? -ne 0 ]; then
    printf "\n"
    echo "✕ Error: Failed to log in to source server with account ${SOURCE_ACCOUNT} at ${SOURCE_SERVER}."
    exit 1
fi

printf '\n'

# By using an API Key, we need to unlock the vault to get a sessionID
echo "# Unlocking the vault..."
SOURCE_SESSION=$(bw unlock "$SOURCE_PASSWORD" --raw)

if [ -z "$SOURCE_SESSION" ]; then
    echo "✕ Error: No source session retrieved. Check your source credentials and try again."
    exit 1
fi

# Synchronizing the vault
echo "# Synchronizing the vault..."
bw sync --session "$SOURCE_SESSION"
printf '\n'


#---------------#
# SOURCE EXPORT #
#---------------#

echo "# Exporting all items..."
bw --session "$SOURCE_SESSION" export --raw --format json > "$SOURCE_OUTPUT_FILE_PATH"

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to export data."
    exit 1
fi

fix_permissions "$PUID" "$PGID" "$SOURCE_OUTPUT_FILE_PATH"

#-----------------------#
# SOURCE EXPORT ENCRYPT #
#-----------------------#

# Encrypt the exported file
encrypt_file "$SOURCE_OUTPUT_FILE_PATH" "$ENCRYPTED_SOURCE_OUTPUT_FILE_PATH" "$ENCRYPTION_PASSWORD"
fix_permissions "$PUID" "$PGID" "$ENCRYPTED_SOURCE_OUTPUT_FILE_PATH"

# Remove the unencrypted file
echo "# Removed unencrypted file."
rm -f "$SOURCE_OUTPUT_FILE_PATH"

sleep 1

#---------------#
# SOURCE LOGOUT #
#---------------#
echo "# Locking the vault..."
bw lock
echo ""

# Logout
echo "# Logging out from Bitwarden..."
bw logout >/dev/null

unset BW_CLIENTID
unset BW_CLIENTSECRET

echo "########## End of Backup process ##########"

sleep 1


#---------#
# RESTORE #
#---------#

# Restoring process
echo "########## Start of Restore process ##########"

# We want to remove items later, so we set a base filename now
DEST_EXPORT_OUTPUT_BASE="bw_export_dest_"
DEST_NEW_FILENAME="$DEST_EXPORT_OUTPUT_BASE$TIMESTAMP.json" #DEST_OUTPUT_FILE
DEST_OUTPUT_FILE_PATH="$DEST_FOLDER/$DEST_NEW_FILENAME"
ENCRYPTED_DEST_OUTPUT_FILE_PATH="$DEST_OUTPUT_FILE_PATH.enc"


#------------#
# DEST PURGE #
#------------#

purge_folder "$DEST_FOLDER" "$MIN_FILES" "$RETENTION_DAYS"
sleep 1

#------------#
# DEST LOGIN #
#------------#

export BW_CLIENTID=${DEST_CLIENT_ID}
export BW_CLIENTSECRET=${DEST_CLIENT_SECRET}


# Login to our Server
echo "# Logging into Dest server..."
bw config server "$DEST_SERVER"

bw login "$DEST_ACCOUNT" --apikey --raw

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to log in to destination server with account ${DEST_ACCOUNT} at ${DEST_SERVER}."
    exit 1
fi

printf '\n'

# By using an API Key, we need to unlock the vault to get a sessionID
echo "# Unlocking the vault..."
DEST_SESSION=$(bw unlock "$DEST_PASSWORD" --raw)

if [ -z "$DEST_SESSION" ]; then
    echo "✕ Error: No destination session retrieved. Check your destination credentials and try again."
    exit 1
fi

# Synchronizing the vault
echo "# Synchronizing the vault..."
bw sync --session "$DEST_SESSION"
printf '\n'


#-------------#
# DEST EXPORT #
#-------------#

# Export what's currently in the vault, so we can remove it
echo "# Exporting current items from destination vault..."
bw --session "$DEST_SESSION" export --raw --format json > "$DEST_OUTPUT_FILE_PATH"

if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to export data."
    exit 1
fi

fix_permissions "$PUID" "$PGID" "$DEST_OUTPUT_FILE_PATH"

#---------------------#
# DEST EXPORT ENCRYPT #
#---------------------#

# Encrypt the exported file
echo "# Encrypting exported file..."
encrypt_file "$DEST_OUTPUT_FILE_PATH" "$ENCRYPTED_DEST_OUTPUT_FILE_PATH" "$ENCRYPTION_PASSWORD"
fix_permissions "$PUID" "$PGID" "$ENCRYPTED_DEST_OUTPUT_FILE_PATH"

sleep 1

#-----------------#
# DEST REMOVE OLD #
#-----------------#

# Find and remove all folders, items, attachments, and org collections
echo "# Removing items from the destination vault... This might take some time."

### FOLDERS
total_folders=$(jq '.folders | length' "$DEST_OUTPUT_FILE_PATH")

if [ -z "$total_folders" ] || [ "$total_folders" -eq 0 ]; then
    echo "# No folders found to delete."
else
    current_folder=0

    # Loop on folders to remove
    for id in $(jq -r '.folders[]? | .id' "$DEST_OUTPUT_FILE_PATH"); do
        current_folder=$((current_folder + 1))
        echo "# Deleting folder [$current_folder/$total_folders]"
    
        # Delete folder
        bw --session "$DEST_SESSION" --raw delete -p folder "$id"
    done

    echo "# Folders deleted successfully."
fi

sleep 1

### ITEMS
total_items=$(jq '.items | length' "$DEST_OUTPUT_FILE_PATH")

if [ -z "$total_items" ] || [ "$total_items" -eq 0 ]; then
    echo "# No items found to delete."
else
    current_item=0

    # Loop sugli ID con progresso
    for id in $(jq -r '.items[]? | .id' "$DEST_OUTPUT_FILE_PATH"); do
        current_item=$((current_item + 1))
        echo "# Deleting item [$current_item/$total_items]"

        # Rimuovi l'elemento
        bw --session "$DEST_SESSION" --raw delete -p item "$id"
    done

    echo "# Items deleted successfully."
fi

sleep 1

### ATTACHMENTS
total_attach=$(jq '.attachments | length' "$DEST_OUTPUT_FILE_PATH")

if [ -z "$total_attach" ] || [ "$total_attach" -eq 0 ]; then
    echo "# No attachments found to delete."
else
    current_attach=0

    # Loop sugli ID con progresso
    for id in $(jq -r '.attachments[]? | .id' "$DEST_OUTPUT_FILE_PATH"); do
        current_attach=$((current_attach + 1))
        echo "# Deleting attachment [$current_attach/$total_attach]"

        # Rimuovi l'elemento
        bw --session "$DEST_SESSION" --raw delete -p attachment "$id"
    done

    echo "# Attachments deleted successfully."
fi


echo "# Vault purged successfully."
echo "# Total removed -> Folders:[${total_folders:-"0"}] - Items:[${total_items:-"0"}] - Attachments:[${total_attach:-"0"}]"

# Remove the unencrypted file
echo "# Removed unencrypted file"
rm -f "$DEST_OUTPUT_FILE_PATH"

sleep 1

#---------------------------#
# DEST IMPORT SOURCE BACKUP #
#---------------------------#

DEST_LATEST_BACKUP="$ENCRYPTED_SOURCE_OUTPUT_FILE_PATH" #Latest source backup encrypted
DECRYPTED_SOURCE_OUTPUT_FILE_PATH="$SOURCE_OUTPUT_FILE_PATH" #Latest source backup

# Decrypt the latest backup
echo "# Decrypting the latest backup..."
decrypt_file "$DEST_LATEST_BACKUP" "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH" "$ENCRYPTION_PASSWORD"
fix_permissions "$PUID" "$PGID" "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH"


# Import the decrypted backup
echo "# Importing the decrypted backup: $DECRYPTED_SOURCE_OUTPUT_FILE_PATH"
bw --session "$DEST_SESSION" --raw import bitwardenjson "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH"
if [ $? -ne 0 ]; then
    echo "✕ Error: Failed to import data."
    exit 1
fi

# Remove the decrypted file
rm -f "$DECRYPTED_SOURCE_OUTPUT_FILE_PATH"
echo "# Decrypted backup imported and removed."


#-------------#
# DEST LOGOUT #
#-------------#

echo "# Locking the vault and logout from destination server..."
bw lock > /dev/null

bw logout > /dev/null

echo "########## End of Restore Process ##########"

unset BW_CLIENTID
unset BW_CLIENTSECRET
