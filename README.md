# TrueNAS Backup Script

This repository provides an automated backup script for TrueNAS SCALE configuration files using Bash and Git. The script downloads the TrueNAS config via API, stores it (optionally with secret seed), manages backup retention, and can push the backup files to a GitHub repository for offsite storage.

## Features

- **Automated config backups** using the TrueNAS WebSocket API (`/api/current`)
- **Optionally includes Secret Seed** for full disaster recovery
- **Backup retention**: automatically deletes oldest backups beyond a set limit
- **Git integration**: stores backups in a Git repository and pushes to GitHub
- **Versioned directories:** Backups are organized by TrueNAS version

## Prerequisites

- Bash shell (Linux/UNIX environment, tested on TrueNAS SCALE)
- python3 (standard library only – no extra packages required)
- git
- A GitHub repository for remote backup storage
- TrueNAS API key with config backup permissions

## Usage

1. **Clone this repository or download the script**

   ```sh
   git clone https://github.com/cavazos-apps/truenas-backup-script.git
   cd truenas-backup-script
   ```

2. **Edit the script variables**

   Open `backup_config.sh` in your favorite editor and configure these variables at the top:

   ```sh
   serverURL="http(s)://<your-truenas-ip-or-host>"
   apiKey="<your-api-key>"
   secSeed=true           # true to include Secret Seed, false otherwise
   backuploc="/path/to/backup/location"
   maxnrOfFiles=7         # Number of backups to keep (0 = unlimited)
   gitUrl="git@github.com:youruser/yourrepo.git"
   ```

3. **Make the script executable**

   ```sh
   chmod +x backup_config.sh
   ```

4. **Run the script**

   ```sh
   ./backup_config.sh
   ```

## How it Works

- Retrieves the current TrueNAS version to create versioned backup directories
- Uses the TrueNAS WebSocket API (`/api/current`) to download the config file (optionally with Secret Seed)
- Stores the backup file in `$backuploc/<version>/`
- Keeps only the latest `$maxnrOfFiles` backups (unless set to 0)
- Initializes a Git repo (if needed), commits changes, and pushes to your remote GitHub repo

## Important Notes

- **Ensure your API Key and URLs are correct.** The script will not validate backup integrity.
- **Backups with Secret Seed** are essential for full system restoration, but should be stored securely.
- **GitHub repo** must be initialized and accessible via SSH or HTTPS depending on your `gitUrl`.
- The script is intended to be run manually or via cron for scheduled backups.

## Credits

Thanks to ‘NasKar’ and ‘engedics’ for sharing ideas on the [TrueNAS forums](https://www.truenas.com/community/threads/best-way-to-get-auto-config-backup.94537/).
