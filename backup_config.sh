# Script to backup TrueNAS SCALE configuration file
# WARNING: DOES NOT CHECK IF A VALID BACKUP IS ACTUALLY CREATED
#
#
# Thanks to 'NasKar' and 'engedics' from this thread: https://www.truenas.com/community/threads/best-way-to-get-auto-config-backup.94537/
#
#
# If a valid backup file is not created then there is something wrong with the API call
# Check that your URL and API Key are both correct
#
# Uses the TrueNAS WebSocket API (/api/current) to avoid the deprecated REST API (/api/v2.0/)
#


# # # # # # # # # # # # # # # #
# USER CONFIGURABLE VARIABLES #
# # # # # # # # # # # # # # # #


# Server IP or URL (include http(s)://)
serverURL=""

# TrueNAS API key (Generate from 'User Icon' -> 'API Keys' in TrueNAS WebGUI)
apiKey=""

# Include Secret Seed (true| false)
secSeed=

# Path on server to store backups
backuploc=""

# Max number of backups to keep (set as 0 to never delete anything)
maxnrOfFiles=

# The SSH URL for your GitHub repository
gitUrl=


# # # # # # # # # # # # # # # # # #
# END USER CONFIGURABLE VARIABLES #
# # # # # # # # # # # # # # # # # #


echo
echo "Backing up current TrueNAS config"

# Check current TrueNAS version number
versiondir=`cat /etc/version | cut -d' ' -f1`

# Set directory for backups to: 'path on server' / 'current version number'
backupMainDir="${backuploc}/${versiondir}"

# Create directory for for backups (Location/Version)
mkdir -p $backupMainDir


# Use appropriate extention if we are exporting the secret seed
if [ $secSeed = true ]
then
    fileExt="tar"
    echo "Secret Seed will be included"
else
    fileExt="db"
    echo "Secret Seed will NOT be included"
fi

# Generate file name
fileName=$(hostname)-TrueNAS-$(date +%Y%m%d).$fileExt


# WebSocket API call to backup config (replaces deprecated REST /api/v2.0/config/save)
TRUENAS_SERVER="$serverURL" \
TRUENAS_API_KEY="$apiKey" \
TRUENAS_SEC_SEED="$secSeed" \
TRUENAS_OUTPUT="$backupMainDir/$fileName" \
python3 - << 'PYEOF'
import sys, json, ssl, socket, struct, base64, os, urllib.request

server   = os.environ["TRUENAS_SERVER"].rstrip("/")
api_key  = os.environ["TRUENAS_API_KEY"]
sec_seed = os.environ["TRUENAS_SEC_SEED"].lower() == "true"
out_file = os.environ["TRUENAS_OUTPUT"]

use_ssl   = server.startswith("https://")
host_part = server.replace("https://", "").replace("http://", "")
host, _, port_s = host_part.partition(":")
port = int(port_s) if port_s else (443 if use_ssl else 80)

# Open TCP connection (with TLS when needed)
# SSL certificate verification is disabled to support self-signed certificates,
# which are common on home TrueNAS deployments. Set verify_mode = ssl.CERT_REQUIRED
# and check_hostname = True if your server uses a trusted certificate.
sock = socket.create_connection((host, port), timeout=60)
if use_ssl:
    tls_ctx = ssl.create_default_context()
    tls_ctx.check_hostname = False
    tls_ctx.verify_mode = ssl.CERT_NONE
    sock = tls_ctx.wrap_socket(sock, server_hostname=host)

# WebSocket opening handshake
ws_key = base64.b64encode(os.urandom(16)).decode()
sock.sendall((
    "GET /api/current HTTP/1.1\r\n"
    "Host: {}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "Sec-WebSocket-Key: {}\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    "\r\n"
).format(host, ws_key).encode())

buf = b""
while b"\r\n\r\n" not in buf:
    chunk = sock.recv(4096)
    if not chunk:
        print("Connection closed during WebSocket handshake", file=sys.stderr)
        sys.exit(1)
    buf += chunk
first_line = buf.split(b"\r\n")[0].decode("utf-8", errors="replace")
if "101" not in first_line:
    print("WebSocket upgrade failed: " + first_line, file=sys.stderr)
    sys.exit(1)

def read_exact(n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("Connection closed unexpectedly")
        data += chunk
    return data

def ws_send(msg):
    payload = msg.encode("utf-8")
    n, mask = len(payload), os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    if n < 126:
        header = bytes([0x81, 0x80 | n])
    elif n < 65536:
        header = bytes([0x81, 0xFE]) + struct.pack(">H", n)
    else:
        header = bytes([0x81, 0xFF]) + struct.pack(">Q", n)
    sock.sendall(header + mask + masked)

def ws_recv():
    while True:
        hdr = read_exact(2)
        opcode = hdr[0] & 0x0F
        length = hdr[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", read_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", read_exact(8))[0]
        payload = read_exact(length)
        if opcode == 0x9:  # ping - reply with pong
            mask = os.urandom(4)
            masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            sock.sendall(bytes([0x8A, 0x80 | len(payload)]) + mask + masked)
            continue
        if opcode == 0xA:  # pong - ignore
            continue
        if opcode == 0x8:  # close
            raise ConnectionError("Server closed the WebSocket connection")
        return payload.decode("utf-8")

# Authenticate with API key (JSON-RPC 2.0)
ws_send(json.dumps({"jsonrpc": "2.0", "id": 1,
                    "method": "auth.login_with_api_key", "params": [api_key]}))
auth = json.loads(ws_recv())
if not auth.get("result"):
    sock.close()
    print("Authentication failed – check your API key.", file=sys.stderr)
    sys.exit(1)

# Request config download via core.download
ws_send(json.dumps({"jsonrpc": "2.0", "id": 2,
                    "method": "core.download",
                    "params": ["config.save", [{"secretseed": sec_seed}], "truenas.db"]}))
dl = json.loads(ws_recv())
sock.close()

if "error" in dl:
    print("core.download error: " + str(dl["error"]), file=sys.stderr)
    sys.exit(1)

download_path = dl["result"][1]
dl_url = download_path if download_path.startswith("http") else server + download_path

# Download the config file via HTTP (SSL verification also disabled for the same reason)
dl_ctx = ssl.create_default_context()
dl_ctx.check_hostname = False
dl_ctx.verify_mode = ssl.CERT_NONE
req = urllib.request.Request(dl_url, headers={"Authorization": "Bearer " + api_key})
with urllib.request.urlopen(req, context=dl_ctx) as resp:
    with open(out_file, "wb") as f:
        f.write(resp.read())
PYEOF

echo
echo "Config saved to ${backupMainDir}/${fileName}"

#
# The next section checks for and deletes old backups
#
# Will not run if $maxnrOfFiles is set to zero (0)
#

if [ ${maxnrOfFiles} -ne 0 ]
then
    echo
    echo "Checking for old backups to delete"
    echo "Number of files to keep: ${maxnrOfFiles}"

    # Get number of files in the backup directory
    nrOfFiles="$(ls -l ${backupMainDir} | grep -c "^-.*")"

    echo "Current number of files: ${nrOfFiles}"

    # Only do something if the current number of files is greater than $maxnrOfFiles
     if [ ${maxnrOfFiles} -lt ${nrOfFiles} ]
     then
         nFileToRemove="$((nrOfFiles - maxnrOfFiles))"
         echo "Removing ${nFileToRemove} file(s)"
          while [ $nFileToRemove -gt 0 ]
          do
             fileToRemove="$(ls -t ${backupMainDir} | tail -1)"
             echo "Removing file ${fileToRemove}"
             nFileToRemove="$((nFileToRemove - 1))"
             rm ${backupMainDir}/${fileToRemove}
             done
         fi
# Inform the user that no files will be deleded if $maxnrOfFiles is set to zero (0)
else
    echo
    echo "NOT deleting old backups because '\$maxnrOfFiles' is set to 0"
fi

#All Done

echo
echo "DONE!"
echo

# Define the current date
current_date=$(date +%Y%m%d)

# Git commands
cd ${backuploc}

if [ -d .git ]; then
    # Git repository already exists, just add and commit
    git add "*/$(hostname)-TrueNAS-${current_date}.tar"
    git commit -m "Add TrueNAS backup file (${current_date})"
    git add -u
    git commit -m "Remove old backups"
else
    # Git repository does not exist, initialize and add/commit
    git init
    git add "$(hostname)-TrueNAS-${current_date}.tar"
    git commit -m "Add TrueNAS backup file ($(date +'%m/%d/%Y'))"
fi

git remote add origin ${gitUrl}
git push -u origin main
