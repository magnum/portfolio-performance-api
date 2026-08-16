# Portfolio Performance API

Ruby API (Sinatra + Puma) that reads a `.portfolio` file (from Google Drive or disk) and returns **balances for cash accounts and securities accounts**. It also includes two utilities: Fineco transaction import and bidirectional Google Sheets sync.

Demo file for trials and tests: `test/test.portfolio` (password `portfolio`).

## Setup

```bash
cp env.example .env
bundle install
```

For Drive/Sheets: enable the **Google Drive API** and **Google Sheets API**, create a **service account**, and download the JSON. Share the files with the `…@….iam.gserviceaccount.com` email (Viewer for the API only, **Editor** for sync and tests). Drive returns 404 if the service account has no access.

| Variable | Used by | Description |
| --- | --- | --- |
| `API_KEY` | API | Key in `X-Api-Key`, `Authorization: Bearer`, or `?apikey=` |
| `PORTFOLIO_PASSWORD` | API, Fineco, sync | Password for the encrypted `.portfolio` |
| `PORTFOLIO_GOOGLE_DRIVE_FILE_ID` | API, sync | Id (or URL) of the `.portfolio` on Drive |
| `PORTFOLIO_FILE` | local API | Path to a `.portfolio` on disk, if Drive is not configured |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | Drive/Sheets | Service account JSON contents |
| `GOOGLE_APPLICATION_CREDENTIALS` | Drive/Sheets | Alternative: path to the JSON |
| `SYNC_GOOGLE_DRIVE_FILE_ID` | sync | Sync spreadsheet |
| `SYNC_GOOGLE_DRIVE_FILE_ID_TEST` | live tests | Spreadsheet used by sync tests |
| `SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS` | sync | Rows to leave untouched at the top of each sheet. Default `0` |
| `SYNC_GOOGLE_DRIVE_ROWS_CHUNK` | sync | Rows written per Sheets request. Default `100` |
| `SYNC_GOOGLE_DRIVE_PREVIEW_ROWS` | sync | Visible rows per list in the preview. Default `20` |
| `IMPORT_FINECO_XLS_SKIP_LINES` | Fineco | Rows to skip in the export. Default `13` |
| `CACHE_TTL_MINUTES` | API | Default `15` |
| `INCLUDE_RETIRED` | API | Default `true` |
| `PORT` | API | Default `9292` |

## API

Exposes portfolio balances as JSON or CSV. It downloads the `.portfolio` from Drive (or reads `PORTFOLIO_FILE`), decrypts it, computes the balance of each deposit account and the market value of each securities account, and caches the result for `CACHE_TTL_MINUTES` (`?nocache` forces a refresh).

```bash
# Local trial with the demo file, no Drive
API_KEY=dev PORTFOLIO_FILE=test/test.portfolio PORTFOLIO_PASSWORD=portfolio \
  bundle exec puma -C config/puma.rb

curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/health
curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/accounts
curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/accounts.json
curl -sS -H "X-Api-Key: dev" http://127.0.0.1:9292/accounts.csv
curl -sS "http://127.0.0.1:9292/accounts.csv?apikey=dev&locale=it"
curl -sS -H "X-Api-Key: dev" "http://127.0.0.1:9292/accounts?nocache"
```

`GET /accounts` and `GET /accounts.json` → JSON. `GET /accounts.csv` → UTF-8 CSV, `;` separator (`.` decimals with `locale=en`, `,` with `locale=it`). `GET /health` is public. `GET /` is the same as `/accounts`.

Each row has `kind`: `deposit` (cash) or `securities` (no FX conversion). Securities accounts include `reference_account_uuid`.

Docker:

```bash
docker build -t portfolio-performance-api .
docker run --env-file .env -p 9292:80 portfolio-performance-api
```

## Fineco import

Imports transactions from a Fineco export (`.xls` / `.xlsx`) into a protobuf `.portfolio`. It only proposes rows dated **after** the account’s last transaction; you choose which ones to import. It uses `Data_Valuta`, `Entrate` → `DEPOSIT`, `Uscite` → `REMOVAL`. The note is `Descrizione Descrizione_Completa Categoria: Moneymap`. Before writing it creates a backup `name-YYYYMMDDTHHMMSS.portfolio`.

Needs an interactive terminal and `bundle install` without `BUNDLE_WITHOUT=utils`. Close Portfolio Performance before importing.

```bash
ruby utils/import-fineco.rb EUR010069756 $HOME/finance/portfolio1.portfolio ./movements.xlsx
```

↑/↓ to move, space to select, first row `toggle all`, Enter to confirm, then `y`. Password: `PORTFOLIO_PASSWORD`, or you are prompted.

## Spreadsheet sync

Aligns transactions both ways for every deposit and securities account in the Drive `.portfolio` (`PORTFOLIO_GOOGLE_DRIVE_FILE_ID`) with a spreadsheet (`SYNC_GOOGLE_DRIVE_FILE_ID`). For each account it prepares two plans, shows the **PORTFOLIO** and **SPREADSHEET** lists, then asks what to write.

Identity: SHA-256 hash of account + date + amount + description + destination (recomputed at runtime, not stored). Create-or-update, no deletes. Spreadsheet type wins; the Portfolio Performance UUID is kept. `amount` is a number with `.` decimal (US locale sheet). Writes in chunks of `SYNC_GOOGLE_DRIVE_ROWS_CHUNK` rows.

Share the spreadsheet and `.portfolio` as **Editor**. Close Portfolio Performance before syncing.

```bash
bin/sync
bin/sync cleanup
```

Keys: ↑/↓ one row, `u`/`v` page, **S** spreadsheet only, **P** portfolio only, **B** both, **Esc** skip the account. The `.portfolio` is uploaded to Drive once at the end if at least one account chose P or B.

`bin/sync cleanup` clears one sheet at a time (rows above the header and the header stay). Confirm with `y` / `n` / `a` (all remaining sheets), **Esc** = no.

Columns: `date`, `type`, `amount`, `currency`, `description`, `destination`, `uuid`. `SYNC_GOOGLE_DRIVE_FILE_SKIP_ROWS` leaves the first N rows untouched.

## Tests

The demo file `test/test.portfolio` (password `portfolio`) is Portfolio Performance’s sample portfolio. Sync tests always use it. Live tests (`test/sync_sheets_test.rb`) empty the `SYNC_GOOGLE_DRIVE_FILE_ID_TEST` spreadsheet, create one sheet per account, and **leave the data** at the end (no cleanup). The spreadsheet must be shared as Editor with the service account.

```bash
# Full suite (live tests are skipped if SYNC_GOOGLE_DRIVE_FILE_ID_TEST is missing)
bundle exec rake test

# In-memory sync only, on the demo file
bundle exec rake test TEST=test/sync_demo_test.rb

# Live sync only, against the test spreadsheet
bundle exec rake test TEST=test/sync_sheets_test.rb
```

Without a complete `.env` the suite still passes: Google tests are skipped.

## Deploy (Kamal)

Needs a VPS with Docker and SSH, and a domain pointing at the server. Images stay on the local registry (`localhost:5555`).

1. In `config/deploy.yml` set the server IP and `proxy.host`.
2. `set -a && source .env && set +a`
3. First setup: `bundle exec kamal setup`
4. Later deploys: `bundle exec kamal deploy`

`kamal-proxy` listens on 80/443, Let’s Encrypt certificate, healthcheck `GET /health`.

```bash
bundle exec kamal logs
bundle exec kamal shell
```
