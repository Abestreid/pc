# PC inventory receiver

PHP 8.2 with ZipArchive. No database, Composer, GitHub token or client secret required.

Deploy `pc/index.php`, `pc/.htaccess`, `pc/.user.ini`, plus the repository's **UTF-8 BOM** `PcSaleInventory.ps1` to `/hosting1/abeslabby/test.abeslab.by/pc/`.

Create `/hosting1/abeslabby/pc-inventory-data/config.php` **outside the web root** using `config.example.php`. Set `storage` to that directory, `base_url` to `https://test.abeslab.by/pc`, and generate a random 32-byte hex `rate_salt` for hashing IP addresses. Do not commit the real config or reports. The PHP process needs write access to this directory. For local tests the config path can be set through `PC_INVENTORY_CONFIG`.

The user explicitly requested no passwords or login: uploading, listing and reading reports are public at `/pc/`. Reports contain hardware/Windows inventory and available disk event messages; the application does not collect browser passwords or personal documents. Each report has a random identifier to avoid collisions, not as an access-control mechanism.

Routes (query parameters do not need URL rewriting):

- `GET /pc/`: launch command, manual upload form and all reports.
- `GET /pc/?action=health`: minimal health response.
- `POST /pc/?action=upload`: raw `application/zip`, header `X-Inventory-Timestamp: ddMMyyyyHHmmss`; or multipart `archive` file and `timestamp` field. Returns 201 JSON with `ok`, `url`, `filename`, `sha256`.
- `GET /pc/?report=<id>`: individual report summary.
- `GET /pc/?action=download&report=<id>`: download ZIP.
- `GET /pc/?action=text&report=<id>`: plain-text report (never rendered as HTML).

ZIP validation requires `inventory.json`, `inventory.txt`, `inventory.csv`, `manual-checklist.txt`. Optional entries must match `smartctl-disk-<number>.txt`. Unknown paths, duplicate names, encryption, oversized entries and invalid inventory schema are rejected. Archives are never extracted or executed. Limits: 8 MiB compressed, 16 MiB uncompressed, 4 MiB per entry, 50 entries, 15 successful uploads/hour/IP and 100/hour globally. IPs are HMAC-hashed in rate state. Storage caps: 512 MiB and 2,000 archives. A global file lock serializes quota checks and storage writes. Existing reports are never automatically deleted or overwritten.

Deployment verification: PHP lint; PowerShell 5.1 fixture run; HTTP upload of fictional `TEST-PC-DEMO` report; returned SHA-256 and byte-for-byte ZIP download; text/Cyrillic, manual multipart upload, public listing, malformed ZIP/schema/path/extension/size and rate-limit checks. Do not upload the deployment computer's actual hardware inventory for testing.
